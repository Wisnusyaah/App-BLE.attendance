// lib/auto_attendance_page.dart

import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_reactive_ble/flutter_reactive_ble.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';

import 'auth_page.dart'; // AttendanceService (pastikan markAttendance ada di sini / service kamu)
import 'attendance_window_service.dart';
import 'schedule_service.dart';
import 'enrollment_service.dart';
import 'teacher_attendance_page.dart';

/// UUID iBeacon sistem
const String kTargetUuid = '00112233-4455-6677-8899-aabbccddeeff';

class IBeaconData {
  final String uuid;
  final int major;
  final int minor;
  final int txPower;

  IBeaconData({
    required this.uuid,
    required this.major,
    required this.minor,
    required this.txPower,
  });
}

bool isIBeacon(Uint8List mfd) {
  if (mfd.length < 4) return false;
  return mfd[0] == 0x4c && mfd[1] == 0x00 && mfd[2] == 0x02 && mfd[3] == 0x15;
}

String _formatUuidFromBytes(Uint8List uuidBytes) {
  final hex = uuidBytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  return '${hex.substring(0, 8)}-'
      '${hex.substring(8, 12)}-'
      '${hex.substring(12, 16)}-'
      '${hex.substring(16, 20)}-'
      '${hex.substring(20, 32)}';
}

IBeaconData? parseIBeacon(Uint8List mfd) {
  if (!isIBeacon(mfd) || mfd.length < 25) return null;

  final uuidBytes = mfd.sublist(4, 20);
  final uuid = _formatUuidFromBytes(uuidBytes).toLowerCase();
  final major = (mfd[20] << 8) | mfd[21];
  final minor = (mfd[22] << 8) | mfd[23];
  final txPower = mfd[24].toSigned(8);

  return IBeaconData(uuid: uuid, major: major, minor: minor, txPower: txPower);
}

double estimateDistance(int rssi, int txPower, {double n = 2.0}) {
  final ratio = (txPower - rssi) / (10 * n);
  return pow(10, ratio).toDouble();
}

Future<bool> requestBlePermissions() async {
  if (!Platform.isAndroid) return false;

  final statuses =
      await [
        Permission.bluetoothScan,
        Permission.bluetoothConnect,
        Permission.location,
      ].request();

  final scanGranted = statuses[Permission.bluetoothScan]?.isGranted ?? false;
  final connectGranted =
      statuses[Permission.bluetoothConnect]?.isGranted ?? false;
  final locationGranted = statuses[Permission.location]?.isGranted ?? false;

  if (!scanGranted || !connectGranted) {
    debugPrint('Missing required BLE permissions.');
    return false;
  }

  if (!locationGranted) {
    debugPrint(
      'WARNING: Location not granted. BLE scans may fail on Android 11 and below.',
    );
  }

  return true;
}

class ScanLogEntry {
  final DateTime timestamp;
  final String deviceId;
  final int rssi;
  final int major;
  final int minor;
  final double distanceMeters;

  ScanLogEntry({
    required this.timestamp,
    required this.deviceId,
    required this.rssi,
    required this.major,
    required this.minor,
    required this.distanceMeters,
  });
}

enum SimulationStatus { noBeacon, collecting, notEligible, ready }

class _RssiSample {
  final DateTime time;
  final int rssi;
  final double distance;

  _RssiSample(this.time, this.rssi, this.distance);
}

class _BeaconInfo {
  final String id;
  final int count;
  final Duration stableDuration;
  final double minRssi;
  final double maxRssi;
  final double avgRssi;
  final double avgDist;
  final IBeaconData? meta;
  final double lastRssi;

  _BeaconInfo({
    required this.id,
    required this.count,
    required this.stableDuration,
    required this.minRssi,
    required this.maxRssi,
    required this.avgRssi,
    required this.avgDist,
    required this.meta,
    required this.lastRssi,
  });
}

class AutoAttendancePage extends StatefulWidget {
  final User user;

  const AutoAttendancePage({super.key, required this.user});

  @override
  State<AutoAttendancePage> createState() => _AutoAttendancePageState();
}

class _AutoAttendancePageState extends State<AutoAttendancePage> {
  final FlutterReactiveBle _ble = FlutterReactiveBle();
  StreamSubscription<DiscoveredDevice>? _scanSub;
  StreamSubscription<BleStatus>? _statusSub;

  BleStatus _bleStatus = BleStatus.unknown;
  bool _permissionsOk = false;
  bool _isScanning = false;

  /// Status presensi untuk sesi (attendance window) yang sedang aktif.
  /// - one_time: cukup check-in sekali
  /// - checkin_checkout: butuh check-in + check-out
  bool _checkinSent = false;
  bool _checkoutSent = false;
  bool _checkinInFlight = false;

  String? _activeWindowId;
  String? _activeClassId;
  String? _activeScheduleId;
  String? _activeClassName;
  String? _activeCourseName;
  String _activeAttendanceType = 'one_time';

  // Snapshot kondisi READY terakhir (dipakai untuk checkout)
  IBeaconData? _lastReadyBeacon;
  String? _lastReadyDeviceId;
  double? _lastReadyAvgRssi;
  double? _lastReadyAvgDistance;

  String _statusText = 'Menunggu izin BLE...';

  // RULE BARU: 2 beacon per kelas, rata-rata RSSI
  static const int _minSamplesPerBeacon = 3;
  static const int _minBeaconsRequired = 2;
  static const Duration _minStableDuration = Duration(seconds: 3);
  static const double _maxDistanceMeters = 9.0;
  static const double _avgRssiThresholdInside = -80.0; // dBm

  // Common window & log
  static const Duration _windowSize = Duration(seconds: 6);
  static const int _maxLogEntries = 120;

  final Map<String, List<_RssiSample>> _samplesPerDevice = {};
  final Map<String, IBeaconData> _beaconMeta = {};
  final Map<String, String> _deviceNames = {};
  final List<ScanLogEntry> _logEntries = [];

  String? _activeDeviceId;
  SimulationStatus _simStatus = SimulationStatus.noBeacon;

  double? _avgRssi;
  double? _minRssi;
  double? _maxRssi;
  double? _avgDistance;
  Duration _stableDuration = Duration.zero;
  int _eligibleBeaconCount = 0;

  int? _currentReadyMajor;
  String? _lastAbsenceMessage;

  bool _showRuleDetail = false;
  bool _showBeaconDetailPanel = false; // <— toggle deteksi beacon

  @override
  void initState() {
    super.initState();
    _bleStatus = _ble.status;
    _statusSub = _ble.statusStream.listen((status) {
      setState(() {
        _bleStatus = status;
      });
    });
    _initFlow();
  }

  Future<void> _initFlow() async {
    final granted = await requestBlePermissions();
    if (!mounted) return;

    setState(() {
      _permissionsOk = granted;
      if (!granted) {
        _statusText =
            'Izinkan Bluetooth & Lokasi supaya auto attendance bisa jalan.';
      } else {
        _statusText = 'Scanning beacon... dekatkan HP ke beacon kelas.';
      }
    });

    if (granted) {
      _startScan();
    }
  }

  void _startScan() {
    if (!_permissionsOk) return;

    _scanSub?.cancel();
    _samplesPerDevice.clear();
    _beaconMeta.clear();
    _logEntries.clear();
    _activeDeviceId = null;
    _simStatus = SimulationStatus.noBeacon;
    _avgRssi = _minRssi = _maxRssi = _avgDistance = null;
    _stableDuration = Duration.zero;
    _eligibleBeaconCount = 0;
    _currentReadyMajor = null;
    _lastAbsenceMessage = null;

    setState(() {
      _isScanning = true;
      _statusText = 'Scanning beacon... dekatkan HP ke beacon kelas.';
    });

    _scanSub = _ble
        .scanForDevices(withServices: const [], scanMode: ScanMode.lowLatency)
        .listen(
          (device) {
            final mfd = device.manufacturerData;
            if (mfd.isEmpty) return;

            final data = parseIBeacon(mfd);
            if (data == null) return;

            if (data.uuid != kTargetUuid) return;

            final now = DateTime.now();
            final distance = estimateDistance(device.rssi, data.txPower);
            final name = device.name.isNotEmpty ? device.name : '(no name)';

            final logEntry = ScanLogEntry(
              timestamp: now,
              deviceId: device.id,
              rssi: device.rssi,
              major: data.major,
              minor: data.minor,
              distanceMeters: distance,
            );

            setState(() {
              _deviceNames[device.id] = name;
              _beaconMeta[device.id] = data;

              _logEntries.add(logEntry);
              if (_logEntries.length > _maxLogEntries) {
                _logEntries.removeAt(0);
              }

              final samples = _samplesPerDevice[device.id] ?? <_RssiSample>[];
              samples.add(_RssiSample(now, device.rssi, distance));
              samples.removeWhere((s) => now.difference(s.time) > _windowSize);
              _samplesPerDevice[device.id] = samples;

              _recomputeSimulation();
            });
          },
          onError: (Object e) {
            debugPrint('Auto attendance scan error: $e');
            setState(() {
              _isScanning = false;
              _statusText = 'Scan error: $e';
            });
          },
        );
  }

  void _recomputeSimulation() {
    if (_samplesPerDevice.isEmpty) {
      _simStatus = SimulationStatus.noBeacon;
      _activeDeviceId = null;
      _avgRssi = _minRssi = _maxRssi = _avgDistance = null;
      _stableDuration = Duration.zero;
      _eligibleBeaconCount = 0;
      _currentReadyMajor = null;
      return;
    }

    final prevStatus = _simStatus;

    // device aktif = RSSI terakhir paling kuat (untuk display)
    String? bestId;
    int? bestRssi;
    _samplesPerDevice.forEach((id, samples) {
      if (samples.isEmpty) return;
      final lastRssi = samples.last.rssi;
      if (bestRssi == null || lastRssi > bestRssi!) {
        bestRssi = lastRssi;
        bestId = id;
      }
    });
    _activeDeviceId = bestId;

    if (_activeDeviceId == null) {
      _simStatus = SimulationStatus.noBeacon;
      _avgRssi = _minRssi = _maxRssi = _avgDistance = null;
      _stableDuration = Duration.zero;
      _eligibleBeaconCount = 0;
      _currentReadyMajor = null;
      return;
    }

    // Kumpulkan info semua beacon
    final List<_BeaconInfo> allBeacons = [];
    bool anyHasEnoughOrLong = false;

    _samplesPerDevice.forEach((id, samples) {
      if (samples.isEmpty) return;

      final count = samples.length;
      final stableDuration = samples.last.time.difference(samples.first.time);
      final rssiValues = samples.map((s) => s.rssi).toList();
      final distances = samples.map((s) => s.distance).toList();

      final minRssi = rssiValues.reduce(min).toDouble();
      final maxRssi = rssiValues.reduce(max).toDouble();
      final avgRssi =
          rssiValues.reduce((a, b) => a + b) / count.toDouble();
      final avgDist =
          distances.reduce((a, b) => a + b) / count.toDouble();
      final lastRssi = samples.last.rssi.toDouble();

      if (count >= _minSamplesPerBeacon ||
          stableDuration >= _minStableDuration) {
        anyHasEnoughOrLong = true;
      }

      allBeacons.add(
        _BeaconInfo(
          id: id,
          count: count,
          stableDuration: stableDuration,
          minRssi: minRssi,
          maxRssi: maxRssi,
          avgRssi: avgRssi,
          avgDist: avgDist,
          meta: _beaconMeta[id],
          lastRssi: lastRssi,
        ),
      );
    });

    if (allBeacons.isEmpty) {
      _simStatus = SimulationStatus.noBeacon;
      _avgRssi = _minRssi = _maxRssi = _avgDistance = null;
      _stableDuration = Duration.zero;
      _eligibleBeaconCount = 0;
      _currentReadyMajor = null;
      return;
    }

    // Kelompokkan beacon berdasarkan major
    final Map<int, List<_BeaconInfo>> beaconsByMajor = {};
    for (final beacon in allBeacons) {
      final meta = beacon.meta;
      if (meta == null) continue;
      beaconsByMajor.putIfAbsent(meta.major, () => []).add(beacon);
    }

    _BeaconInfo? chosen1;
    _BeaconInfo? chosen2;
    int? chosenMajor;
    double bestAvgRssi = -9999.0;
    int eligibleCountForChosenMajor = 0;

    beaconsByMajor.forEach((major, beacons) {
      // Filter beacon yang cukup sampel, cukup stabil, dan jarak tidak terlalu jauh
      final eligible = beacons.where((b) {
        final enoughSamples = b.count >= _minSamplesPerBeacon;
        final longEnough = b.stableDuration >= _minStableDuration;
        final nearEnough = b.avgDist <= _maxDistanceMeters;
        return enoughSamples && longEnough && nearEnough;
      }).toList();

      if (eligible.length < _minBeaconsRequired) {
        return;
      }

      eligible.sort((a, b) => b.avgRssi.compareTo(a.avgRssi));
      final b1 = eligible[0];
      final b2 = eligible[1];

      final avgRssiMajor = (b1.avgRssi + b2.avgRssi) / 2.0;

      if (avgRssiMajor > bestAvgRssi) {
        bestAvgRssi = avgRssiMajor;
        chosenMajor = major;
        chosen1 = b1;
        chosen2 = b2;
        eligibleCountForChosenMajor = eligible.length;
      }
    });

    if (chosen1 != null && chosen2 != null && chosenMajor != null) {
      // Update statistik untuk display
      _eligibleBeaconCount = eligibleCountForChosenMajor;
      _avgRssi = bestAvgRssi;
      _avgDistance = (chosen1!.avgDist + chosen2!.avgDist) / 2.0;
      _minRssi = min(chosen1!.minRssi, chosen2!.minRssi);
      _maxRssi = max(chosen1!.maxRssi, chosen2!.maxRssi);
      _stableDuration =
          chosen1!.stableDuration < chosen2!.stableDuration
              ? chosen1!.stableDuration
              : chosen2!.stableDuration;
      _currentReadyMajor = chosenMajor;

      // Simpan snapshot READY terakhir (buat kebutuhan checkout)
      _lastReadyBeacon = chosen1!.meta;
      _lastReadyDeviceId = chosen1!.id;
      _lastReadyAvgRssi = bestAvgRssi;
      _lastReadyAvgDistance = _avgDistance;


      // Tentukan status ready berdasarkan rata-rata RSSI 2 beacon
      if (bestAvgRssi >= _avgRssiThresholdInside) {
        _simStatus = SimulationStatus.ready;
      } else {
        _simStatus = SimulationStatus.notEligible;
      }

      // Trigger auto attendance saat status berubah menjadi READY
      if (_simStatus == SimulationStatus.ready &&
          prevStatus != SimulationStatus.ready &&
          !_checkinInFlight &&
          !_checkinSent &&
          chosen1!.meta != null &&
          _avgRssi != null &&
          _avgDistance != null) {
        _checkinInFlight = true;

        _performAutoAttendanceForMajor(
          major: chosenMajor!,
          beacon: chosen1!.meta!,
          deviceId: chosen1!.id,
          avgRssi: _avgRssi!,
          avgDistance: _avgDistance!,
        );
      }
    } else {
      // Tidak ada kelas yang punya minimal 2 beacon eligible
      _eligibleBeaconCount = 0;
      _avgRssi = _minRssi = _maxRssi = _avgDistance = null;
      _stableDuration = Duration.zero;
      _currentReadyMajor = null;

      if (!anyHasEnoughOrLong) {
        _simStatus = SimulationStatus.collecting;
      } else {
        _simStatus = SimulationStatus.notEligible;
      }
    }
  }

  Future<void> _performAutoAttendanceForMajor({
    required int major,
    required IBeaconData beacon,
    required String deviceId,
    required double avgRssi,
    required double avgDistance,
  }) async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) {
      _checkinSent = false;
      _checkinInFlight = false;
      return;
    }

    try {
      final window = await AttendanceWindowService.findOpenWindowForMajor(
        major: major,
      );
      if (window == null) {
        _showPillSnack(
          context,
          message: 'READY, tapi dosen belum buka sesi absen untuk kelas ini.',
          icon: Icons.info_outline,
        );
        _checkinSent = false;
        return;
      }

      // Kalau sesi (window) berganti, reset status check-in/out lokal.
      if (_activeWindowId != window.id) {
        _activeWindowId = window.id;
        _activeAttendanceType = window.attendanceType;
        _activeClassId = window.classId;
        _activeClassName = window.className;
        _activeScheduleId = null;
        _activeCourseName = null;
        _checkinSent = false;
        _checkoutSent = false;
      }

      // Sudah check-in untuk window ini → tidak perlu kirim lagi.
      if (_checkinSent) return;

      final schedule = await ScheduleService.findActiveScheduleForClass(
        classId: window.classId,
      );
      if (schedule == null) {
        _showPillSnack(
          context,
          message:
              'READY di ${window.className}, tapi belum masuk jam kuliah di jadwal.',
          icon: Icons.schedule,
        );
        _checkinSent = false;
        return;
      }

      final enrolled = await EnrollmentService.isUserEnrolledToClass(
        userId: user.uid,
        classId: window.classId,
      );
      if (!enrolled) {
        _showPillSnack(
          context,
          message:
              'READY di ${window.className}, tapi kamu tidak terdaftar di kelas ini.',
          icon: Icons.block,
        );
        _checkinSent = false;
        return;
      }

      await AttendanceService.markAttendance(
        windowId: window.id,
        eventType: 'checkin',
        classId: window.classId,
        scheduleId: schedule.id,
        className: window.className,
        major: beacon.major,
        minor: beacon.minor,
        uuid: beacon.uuid,
        deviceId: deviceId,
        avgRssi: avgRssi,
        avgDistance: avgDistance,
        courseName: schedule.courseName,
      );

      // Simpan konteks utk checkout
      setState(() {
        _activeWindowId = window.id;
        _activeAttendanceType = window.attendanceType;
        _activeClassId = window.classId;
        _activeClassName = window.className;
        _activeScheduleId = schedule.id;
        _activeCourseName = schedule.courseName;

        _lastReadyBeacon = beacon;
        _lastReadyDeviceId = deviceId;
        _lastReadyAvgRssi = avgRssi;
        _lastReadyAvgDistance = avgDistance;

        _checkinSent = true;
        _lastAbsenceMessage = null;
      });

      final msg = (window.attendanceType == 'checkin_checkout')
          ? 'Check-in tercatat di ${window.className}. Nanti jangan lupa Checkout.'
          : 'Presensi tercatat di ${window.className}.';

      _showPillSnack(
        context,
        message: msg,
        icon: Icons.check_circle,
        success: true,
      );
      _showAttendanceSuccessSheet(
        className: window.className,
        major: beacon.major,
        minor: beacon.minor,
        distance: avgDistance,
        rssi: avgRssi,
        courseName: schedule.courseName,
      );
    } catch (e) {
      debugPrint('Auto attendance error: $e');
      _checkinSent = false;
      _showPillSnack(
        context,
        message: 'Gagal menyimpan absen: $e',
        icon: Icons.error_outline,
      );
    } finally {
      _checkinInFlight = false;
    }
  }


  Future<void> _performCheckout() async {
    // Hanya untuk tipe checkin-checkout
    if (_activeAttendanceType != 'checkin_checkout') return;
    if (!_checkinSent || _checkoutSent) return;

    // Checkout idealnya dilakukan saat status READY (di dalam kelas)
    if (_simStatus != SimulationStatus.ready ||
        _lastReadyBeacon == null ||
        _lastReadyDeviceId == null ||
        _lastReadyAvgRssi == null ||
        _lastReadyAvgDistance == null) {
      _showPillSnack(
        context,
        message: 'Untuk Checkout, pastikan status READY (di dalam kelas).',
        icon: Icons.info_outline,
      );
      return;
    }

    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;

    final windowId = _activeWindowId;
    final classId = _activeClassId;
    final scheduleId = _activeScheduleId;
    final className = _activeClassName;
    if (windowId == null || classId == null || scheduleId == null || className == null) {
      _showPillSnack(
        context,
        message: 'Data sesi belum lengkap. Coba lakukan Check-in dulu.',
        icon: Icons.error_outline,
      );
      return;
    }

    try {
      // Pastikan window masih open
      final wSnap = await FirebaseFirestore.instance
          .collection('attendance_windows')
          .doc(windowId)
          .get();
      final wData = wSnap.data();
      final isOpen = (wData?['isOpen'] as bool?) ?? false;
      if (!isOpen) {
        _showPillSnack(
          context,
          message: 'Sesi absensi sudah ditutup oleh dosen.',
          icon: Icons.info_outline,
        );
        return;
      }

      await AttendanceService.markAttendance(
        windowId: windowId,
        eventType: 'checkout',
        classId: classId,
        scheduleId: scheduleId,
        className: className,
        major: _lastReadyBeacon!.major,
        minor: _lastReadyBeacon!.minor,
        uuid: _lastReadyBeacon!.uuid,
        deviceId: _lastReadyDeviceId!,
        avgRssi: _lastReadyAvgRssi!,
        avgDistance: _lastReadyAvgDistance!,
        courseName: _activeCourseName,
      );

      setState(() => _checkoutSent = true);

      _showPillSnack(
        context,
        message: 'Checkout tercatat. Terima kasih!',
        icon: Icons.check_circle,
        success: true,
      );
    } catch (e) {
      debugPrint('Checkout error: $e');
      _showPillSnack(
        context,
        message: 'Gagal Checkout: $e',
        icon: Icons.error_outline,
      );
    }
  }


  void _showPillSnack(
    BuildContext context, {
    required String message,
    IconData? icon,
    bool success = false,
    bool danger = false,
  }) {
    final bg =
        danger
            ? const Color(0xFFFFE8E8)
            : success
            ? const Color(0xFFE8FFF1)
            : const Color(0xFFF2F4F7);
    final fg =
        danger
            ? const Color(0xFFB42318)
            : success
            ? const Color(0xFF067647)
            : const Color(0xFF344054);
    final ic =
        danger
            ? Icons.error_outline
            : success
            ? Icons.check_circle
            : (icon ?? Icons.info_outline);

    ScaffoldMessenger.of(context).hideCurrentSnackBar();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        behavior: SnackBarBehavior.floating,
        backgroundColor: Colors.transparent,
        elevation: 0,
        content: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          decoration: BoxDecoration(
            color: bg,
            borderRadius: BorderRadius.circular(999),
            border: Border.all(
              color:
                  danger
                      ? const Color(0xFFFDA29B)
                      : success
                      ? const Color(0xFF6CE9A6)
                      : const Color(0xFFD0D5DD),
            ),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withOpacity(0.04),
                blurRadius: 10,
                offset: const Offset(0, 4),
              ),
            ],
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(ic, size: 18, color: fg),
              const SizedBox(width: 8),
              Flexible(
                child: Text(
                  message,
                  style: TextStyle(
                    color: fg,
                    fontWeight: FontWeight.w600,
                    fontSize: 12.5,
                  ),
                ),
              ),
            ],
          ),
        ),
        duration: const Duration(seconds: 3),
        margin: const EdgeInsets.only(bottom: 16, left: 16, right: 16),
      ),
    );
  }

  void _showAttendanceSuccessSheet({
    required String className,
    required int major,
    required int minor,
    required double distance,
    required double rssi,
    String? courseName,
  }) {
    final now = DateTime.now();
    showModalBottomSheet(
      context: context,
      isScrollControlled: false,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (ctx) {
        final titleStyle = Theme.of(context).textTheme.titleMedium?.copyWith(
          fontWeight: FontWeight.w800,
          color: Colors.black87,
        );
        final labelStyle = const TextStyle(
          fontSize: 12.5,
          color: Colors.black54,
        );
        final valueStyle = const TextStyle(
          fontSize: 13.5,
          color: Colors.black87,
          fontWeight: FontWeight.w600,
        );
        return Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Center(
                child: Container(
                  width: 44,
                  height: 5,
                  margin: const EdgeInsets.only(bottom: 14),
                  decoration: BoxDecoration(
                    color: Colors.grey.shade300,
                    borderRadius: BorderRadius.circular(999),
                  ),
                ),
              ),
              Row(
                children: [
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: const Color(0xFFE8FFF1),
                      shape: BoxShape.circle,
                      border: Border.all(color: const Color(0xFF6CE9A6)),
                    ),
                    child: const Icon(
                      Icons.check_rounded,
                      color: Color(0xFF067647),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text('Absen berhasil dicatat!', style: titleStyle),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Text(
                courseName ?? className,
                style: const TextStyle(
                  fontWeight: FontWeight.w700,
                  fontSize: 16.5,
                  color: Colors.black87,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                className,
                style: const TextStyle(fontSize: 13, color: Colors.black54),
              ),
              const SizedBox(height: 10),
              Row(
                children: [
                  _kv(
                    label: 'RSSI',
                    value: '${rssi.toStringAsFixed(1)} dBm',
                    labelStyle: labelStyle,
                    valueStyle: valueStyle,
                  ),
                  const SizedBox(width: 16),
                  _kv(
                    label: 'Jarak',
                    value: '≈ ${distance.toStringAsFixed(2)} m',
                    labelStyle: labelStyle,
                    valueStyle: valueStyle,
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  _kv(
                    label: 'Major',
                    value: '$major',
                    labelStyle: labelStyle,
                    valueStyle: valueStyle,
                  ),
                  const SizedBox(width: 16),
                  _kv(
                    label: 'Minor',
                    value: '$minor',
                    labelStyle: labelStyle,
                    valueStyle: valueStyle,
                  ),
                  const Spacer(),
                  Text(
                    _formatDateTimeShort(now),
                    style: const TextStyle(fontSize: 12, color: Colors.black54),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  onPressed: () => Navigator.of(ctx).pop(),
                  child: const Text('Oke'),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _kv({
    required String label,
    required String value,
    TextStyle? labelStyle,
    TextStyle? valueStyle,
  }) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text('$label: ', style: labelStyle),
        Text(value, style: valueStyle),
      ],
    );
  }

  void _restartScan() => _startScan();

  @override
  void dispose() {
    _scanSub?.cancel();
    _statusSub?.cancel();
    super.dispose();
  }

  String _formatTime(DateTime t) {
    final h = t.hour.toString().padLeft(2, '0');
    final m = t.minute.toString().padLeft(2, '0');
    final s = t.second.toString().padLeft(2, '0');
    return '$h:$m:$s';
  }

  String _formatDateTimeShort(DateTime t) {
    final h = t.hour.toString().padLeft(2, '0');
    final m = t.minute.toString().padLeft(2, '0');
    return '${t.day.toString().padLeft(2, '0')}/${t.month.toString().padLeft(2, '0')} $h:$m';
  }

  Widget _buildLogExpansion(List<ScanLogEntry> logs) {
    return Card(
      child: ExpansionTile(
        leading: const Icon(Icons.bug_report_outlined),
        title: const Text(
          'Debug log scan',
          style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
        ),
        subtitle: const Text(
          'Biasanya tidak perlu dilihat mahasiswa. Untuk debugging RSSI / jarak.',
          style: TextStyle(fontSize: 11),
        ),
        children: [
          if (logs.isEmpty)
            const Padding(
              padding: EdgeInsets.all(12),
              child: Text(
                'Belum ada log scan. Dekatkan HP ke beacon kelas.',
                style: TextStyle(fontSize: 12),
              ),
            )
          else
            Padding(
              padding: const EdgeInsets.only(left: 12, right: 12, bottom: 8),
              child: Column(
                children:
                    logs.map((entry) {
                      return ListTile(
                        dense: true,
                        contentPadding: EdgeInsets.zero,
                        title: Text(
                          '[${_formatTime(entry.timestamp)}] '
                          'RSSI: ${entry.rssi} dBm, '
                          'dist: ${entry.distanceMeters.toStringAsFixed(2)} m',
                          style: const TextStyle(fontSize: 12),
                        ),
                        subtitle: Text(
                          'ID: ${entry.deviceId}\n'
                          'Major: ${entry.major}, Minor: ${entry.minor}',
                          style: const TextStyle(fontSize: 11),
                        ),
                      );
                    }).toList(),
              ),
            ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final email = widget.user.email ?? '(tanpa email)';

    IconData scanIcon;
    Color scanColor;
    final envBad =
        !_permissionsOk ||
        _bleStatus == BleStatus.unauthorized ||
        _bleStatus == BleStatus.poweredOff ||
        _bleStatus == BleStatus.locationServicesDisabled ||
        _bleStatus == BleStatus.unsupported;

    if (envBad) {
      scanIcon = Icons.error_outline;
      scanColor = Colors.red;
    } else if (_isScanning) {
      scanIcon = Icons.bluetooth_searching;
      scanColor = Colors.green;
    } else {
      scanIcon = Icons.bluetooth;
      scanColor = Colors.grey;
    }

    String statusTitle;
    String statusShort;
    Color statusColor;
    IconData statusIcon;

    switch (_simStatus) {
      case SimulationStatus.noBeacon:
        statusTitle = 'Belum ada beacon';
        statusShort = 'Dekatkan HP ke beacon kelas.';
        statusColor = Colors.grey;
        statusIcon = Icons.help_outline;
        break;
      case SimulationStatus.collecting:
        statusTitle = 'Mengumpulkan sinyal';
        statusShort = 'Tunggu sebentar, sistem lagi baca kekuatan sinyal.';
        statusColor = Colors.orange;
        statusIcon = Icons.downloading;
        break;
      case SimulationStatus.notEligible:
        statusTitle = 'Belum siap absen';
        statusShort =
            'Sinyal belum cukup stabil/kuat. Pastikan dekat minimal 2 beacon.';
        statusColor = Colors.red;
        statusIcon = Icons.close;
        break;
      case SimulationStatus.ready:
        statusTitle = 'READY untuk auto absen';
        statusShort =
            'Jika jadwal aktif dan dosen sudah buka sesi, absen otomatis tercatat.';
        statusColor = Colors.green;
        statusIcon = Icons.check_circle;
        break;
    }

    final activeId = _activeDeviceId;
    final activeSamples = activeId != null ? _samplesPerDevice[activeId] : null;
    final sampleCount = activeSamples?.length ?? 0;
    final activeName =
        activeId != null ? (_deviceNames[activeId] ?? '(no name)') : '-';
    final activeMeta = activeId != null ? _beaconMeta[activeId] : null;
    final totalBeaconsTracked = _samplesPerDevice.length;
    final logReversed = _logEntries.reversed.toList();

    return Scaffold(
      appBar: AppBar(
        title: const Text('Auto Attendance'),
        actions: [
          IconButton(
            onPressed: _restartScan,
            icon: const Icon(Icons.refresh),
            tooltip: 'Refresh scan',
          ),
          IconButton(
            onPressed: () async {
              await FirebaseAuth.instance.signOut();
            },
            icon: const Icon(Icons.logout),
            tooltip: 'Logout',
          ),
        ],
      ),
      body: SafeArea(
        child: LayoutBuilder(
          builder: (context, constraints) {
            return SingleChildScrollView(
              child: ConstrainedBox(
                constraints: BoxConstraints(minHeight: constraints.maxHeight),
                child: Padding(
                  padding: const EdgeInsets.only(
                    left: 12,
                    right: 12,
                    bottom: 16,
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      BleEnvironmentBanner(status: _bleStatus),

                      // Salam user
                      Card(
                        child: Padding(
                          padding: const EdgeInsets.all(12),
                          child: Row(
                            children: [
                              CircleAvatar(
                                radius: 22,
                                backgroundColor:
                                    Theme.of(
                                      context,
                                    ).colorScheme.primaryContainer,
                                child: const Icon(Icons.person),
                              ),
                              const SizedBox(width: 12),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    const Text(
                                      'Selamat datang,',
                                      style: TextStyle(fontSize: 12),
                                    ),
                                    Text(
                                      email,
                                      style: const TextStyle(
                                        fontWeight: FontWeight.w600,
                                        fontSize: 15,
                                      ),
                                    ),
                                    const SizedBox(height: 4),
                                    const Text(
                                      'Cukup buka aplikasi dan dekatkan HP ke beacon kelas. Tidak perlu klik tombol absen.',
                                      style: TextStyle(
                                        fontSize: 11,
                                        color: Colors.black54,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),

                      // Status scan (minimal)
                      Card(
                        child: Padding(
                          padding: const EdgeInsets.all(12),
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Container(
                                padding: const EdgeInsets.all(10),
                                decoration: BoxDecoration(
                                  color: scanColor.withOpacity(0.12),
                                  shape: BoxShape.circle,
                                ),
                                child: Icon(scanIcon, color: scanColor),
                              ),
                              const SizedBox(width: 12),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    const Text(
                                      'Status scan BLE',
                                      style: TextStyle(
                                        fontSize: 12,
                                        color: Colors.black54,
                                      ),
                                    ),
                                    const SizedBox(height: 2),
                                    Text(
                                      _statusText,
                                      style: const TextStyle(fontSize: 13),
                                    ),
                                    const SizedBox(height: 10),
                                    Center(
                                      child: SizedBox(
                                        width: 240,
                                        child: ElevatedButton.icon(
                                          onPressed: _restartScan,
                                          style: ElevatedButton.styleFrom(
                                            padding: const EdgeInsets.symmetric(
                                              vertical: 14,
                                              horizontal: 16,
                                            ),
                                            shape: const StadiumBorder(),
                                            elevation: 0,
                                            backgroundColor:
                                                Theme.of(context)
                                                    .colorScheme
                                                    .primaryContainer,
                                            foregroundColor:
                                                Theme.of(context)
                                                    .colorScheme
                                                    .onPrimaryContainer,
                                          ),
                                          icon: Icon(
                                            _isScanning
                                                ? Icons.sync
                                                : Icons.refresh_rounded,
                                            size: 18,
                                          ),
                                          label: Text(
                                            _isScanning
                                                ? 'Scanning, tap untuk refresh'
                                                : 'Refresh scan',
                                          ),
                                        ),
                                      ),
                                    ),
                                    if (_activeAttendanceType == 'checkin_checkout' &&
                                        _checkinSent &&
                                        !_checkoutSent) ...[
                                      const SizedBox(height: 12),
                                      Container(
                                        padding: const EdgeInsets.all(12),
                                        decoration: BoxDecoration(
                                          color: Colors.blueGrey.withOpacity(0.06),
                                          borderRadius: BorderRadius.circular(16),
                                          border: Border.all(color: Colors.blueGrey.withOpacity(0.15)),
                                        ),
                                        child: Column(
                                          crossAxisAlignment: CrossAxisAlignment.start,
                                          children: [
                                            Text(
                                              'Kamu sudah Check-in${_activeClassName != null ? ' di ${_activeClassName!}' : ''}.',
                                              style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
                                            ),
                                            const SizedBox(height: 6),
                                            const Text(
                                              'Saat kuliah selesai, tekan Checkout (harus status READY).',
                                              style: TextStyle(fontSize: 12, color: Colors.black54),
                                            ),
                                            const SizedBox(height: 10),
                                            SizedBox(
                                              width: double.infinity,
                                              child: ElevatedButton.icon(
                                                onPressed: _performCheckout,
                                                icon: const Icon(Icons.logout_rounded, size: 18),
                                                label: const Text('Checkout'),
                                              ),
                                            ),
                                          ],
                                        ),
                                      ),
                                    ],
                                  ],
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),

                      // Status + toggle Deteksi Beacon (DETAIL DIPINDAH KE SINI)
                      Card(
                        child: Padding(
                          padding: const EdgeInsets.all(12),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                children: [
                                  Icon(statusIcon, color: statusColor),
                                  const SizedBox(width: 8),
                                  Expanded(
                                    child: Text(
                                      statusTitle,
                                      style: TextStyle(
                                        fontWeight: FontWeight.bold,
                                        color: statusColor,
                                        fontSize: 14,
                                      ),
                                    ),
                                  ),
                                  // Tombol toggle deteksi beacon
                                  TextButton.icon(
                                    onPressed: () {
                                      setState(
                                        () =>
                                            _showBeaconDetailPanel =
                                                !_showBeaconDetailPanel,
                                      );
                                    },
                                    icon: Icon(
                                      _showBeaconDetailPanel
                                          ? Icons.visibility_off
                                          : Icons.visibility,
                                    ),
                                    label: Text(
                                      _showBeaconDetailPanel
                                          ? 'Sembunyikan'
                                          : 'Lihat deteksi',
                                    ),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 4),
                              Text(
                                statusShort,
                                style: const TextStyle(fontSize: 12),
                              ),
                              const SizedBox(height: 6),

                              // Toggle detail rule
                              Align(
                                alignment: Alignment.centerRight,
                                child: TextButton.icon(
                                  onPressed:
                                      () => setState(
                                        () =>
                                            _showRuleDetail = !_showRuleDetail,
                                      ),
                                  icon: Icon(
                                    _showRuleDetail
                                        ? Icons.expand_less
                                        : Icons.expand_more,
                                  ),
                                  label: Text(
                                    _showRuleDetail
                                        ? 'Sembunyikan rule'
                                        : 'Lihat rule',
                                  ),
                                ),
                              ),
                              AnimatedCrossFade(
                                crossFadeState:
                                    _showRuleDetail
                                        ? CrossFadeState.showFirst
                                        : CrossFadeState.showSecond,
                                duration: const Duration(milliseconds: 220),
                                firstChild: Padding(
                                  padding: const EdgeInsets.only(bottom: 6),
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      const Text(
                                        'Rule penentuan lokasi (2 beacon per kelas):',
                                        style: TextStyle(
                                          fontSize: 11,
                                          fontWeight: FontWeight.bold,
                                        ),
                                      ),
                                      Text(
                                        '  • Minimal $_minBeaconsRequired beacon dengan major yang sama\n'
                                        '  • Setiap beacon minimal $_minSamplesPerBeacon sampel dalam ${_windowSize.inSeconds} detik\n'
                                        '  • Jarak rata-rata tiap beacon ≤ ${_maxDistanceMeters.toStringAsFixed(1)} m\n'
                                        '  • Hitung rata-rata RSSI dari 2 beacon terkuat\n'
                                        '  • Jika rata-rata RSSI ≥ $_avgRssiThresholdInside dBm → status READY',
                                        style: const TextStyle(fontSize: 11),
                                      ),
                                    ],
                                  ),
                                ),
                                secondChild: const SizedBox.shrink(),
                              ),

                              // PANEL DETEKSI BEACON kelas (dipindah dari card bawah)
                              AnimatedSwitcher(
                                duration: const Duration(milliseconds: 220),
                                transitionBuilder:
                                    (child, anim) => SizeTransition(
                                      sizeFactor: anim,
                                      child: child,
                                    ),
                                child:
                                    !_showBeaconDetailPanel
                                        ? const SizedBox.shrink()
                                        : Column(
                                          key: const ValueKey('beacon-detail'),
                                          crossAxisAlignment:
                                              CrossAxisAlignment.start,
                                          children: [
                                            const Divider(height: 16),
                                            const Text(
                                              'Deteksi Beacon Kelas',
                                              style: TextStyle(
                                                fontWeight: FontWeight.bold,
                                              ),
                                            ),
                                            const SizedBox(height: 6),
                                            Wrap(
                                              spacing: 8,
                                              runSpacing: 8,
                                              children: [
                                                _chip(
                                                  icon: Icons.rss_feed,
                                                  label:
                                                      'UUID cocok: $totalBeaconsTracked',
                                                ),
                                                _chip(
                                                  icon: Icons.how_to_vote,
                                                  label:
                                                      'Memenuhi rule: $_eligibleBeaconCount (butuh ≥ $_minBeaconsRequired)',
                                                ),
                                                _chip(
                                                  icon: Icons.device_hub,
                                                  label: 'Terkuat: $activeName',
                                                ),
                                                if (activeMeta != null)
                                                  _chip(
                                                    icon: Icons.tag,
                                                    label:
                                                        'Major ${activeMeta.major} · Minor ${activeMeta.minor}',
                                                  ),
                                                _chip(
                                                  icon: Icons.network_cell,
                                                  label:
                                                      'RSSI avg (2 beacon): ${_avgRssi?.toStringAsFixed(1) ?? '-'} dBm',
                                                ),
                                                _chip(
                                                  icon: Icons.straighten,
                                                  label:
                                                      'Jarak rata-rata ≈ ${_avgDistance?.toStringAsFixed(2) ?? '-'} m',
                                                ),
                                                _chip(
                                                  icon: Icons.timer,
                                                  label:
                                                      'Window ${_stableDuration.inSeconds}s · Sampel $sampleCount',
                                                ),
                                                if (_currentReadyMajor != null)
                                                  _chip(
                                                    icon: Icons.place,
                                                    label:
                                                        'Major terdekat: $_currentReadyMajor',
                                                  ),
                                              ],
                                            ),
                                            if (_lastAbsenceMessage !=
                                                null) ...[
                                              const SizedBox(height: 8),
                                              Container(
                                                padding:
                                                    const EdgeInsets.symmetric(
                                                      horizontal: 10,
                                                      vertical: 8,
                                                    ),
                                                decoration: BoxDecoration(
                                                  color: const Color(
                                                    0xFFE8FFF1,
                                                  ),
                                                  border: Border.all(
                                                    color: const Color(
                                                      0xFF6CE9A6,
                                                    ),
                                                  ),
                                                  borderRadius:
                                                      BorderRadius.circular(12),
                                                ),
                                                child: Row(
                                                  children: [
                                                    const Icon(
                                                      Icons.check_circle,
                                                      color: Color(0xFF067647),
                                                      size: 18,
                                                    ),
                                                    const SizedBox(width: 8),
                                                    Expanded(
                                                      child: Text(
                                                        _lastAbsenceMessage!,
                                                        style: const TextStyle(
                                                          fontSize: 12.5,
                                                          color: Color(
                                                            0xFF067647,
                                                          ),
                                                          fontWeight:
                                                              FontWeight.w600,
                                                        ),
                                                      ),
                                                    ),
                                                  ],
                                                ),
                                              ),
                                            ],
                                          ],
                                        ),
                              ),
                            ],
                          ),
                        ),
                      ),

                      // Tombol mode dosen
                      Row(
                        children: [
                          Expanded(
                            child: OutlinedButton.icon(
                              onPressed: () {
                                Navigator.of(context).push(
                                  MaterialPageRoute(
                                    builder:
                                        (_) => const TeacherAttendancePage(),
                                  ),
                                );
                              },
                              icon: const Icon(Icons.school),
                              label: const Text('Mode dosen'),
                            ),
                          ),
                        ],
                      ),

                      const SizedBox(height: 8),

                      // Hanya log debug, tanpa riwayat absen
                      _buildLogExpansion(logReversed),
                    ],
                  ),
                ),
              ),
            );
          },
        ),
      ),
    );
  }

  Widget _chip({required IconData icon, required String label}) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: Colors.grey.shade100,
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: Colors.grey.shade300),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 16, color: Colors.black54),
          const SizedBox(width: 6),
          Text(label, style: const TextStyle(fontSize: 12.5)),
        ],
      ),
    );
  }
}

/// Banner untuk nunjukin masalah environment BLE (Bluetooth off, dll).
class BleEnvironmentBanner extends StatelessWidget {
  final BleStatus status;

  const BleEnvironmentBanner({super.key, required this.status});

  @override
  Widget build(BuildContext context) {
    final List<Widget> cards = [];

    if (status == BleStatus.poweredOff) {
      cards.add(
        Card(
          color: Colors.red.withOpacity(0.08),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
            side: const BorderSide(color: Colors.red),
          ),
          child: const ListTile(
            leading: Icon(Icons.bluetooth_disabled, color: Colors.red),
            title: Text(
              'Bluetooth mati',
              style: TextStyle(fontWeight: FontWeight.bold),
            ),
            subtitle: Text(
              'Nyalakan Bluetooth supaya scan beacon bisa berjalan.',
            ),
          ),
        ),
      );
    }

    if (status == BleStatus.locationServicesDisabled) {
      cards.add(
        Card(
          color: Colors.orange.withOpacity(0.08),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
            side: const BorderSide(color: Colors.orange),
          ),
          child: const ListTile(
            leading: Icon(Icons.location_off, color: Colors.orange),
            title: Text(
              'Location services mati',
              style: TextStyle(fontWeight: FontWeight.bold),
            ),
            subtitle: Text(
              'Aktifkan Location di perangkat (syarat Android untuk BLE scan).',
            ),
          ),
        ),
      );
    }

    if (status == BleStatus.unauthorized) {
      cards.add(
        Card(
          color: Colors.red.withOpacity(0.08),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
            side: const BorderSide(color: Colors.red),
          ),
          child: ListTile(
            leading: const Icon(Icons.warning_amber_rounded, color: Colors.red),
            title: const Text(
              'Izin Bluetooth / Lokasi ditolak',
              style: TextStyle(fontWeight: FontWeight.bold),
            ),
            subtitle: const Text(
              'Izinkan Bluetooth & Lokasi untuk aplikasi ini di pengaturan.',
            ),
            onTap: () {
              openAppSettings();
            },
          ),
        ),
      );
    }

    if (status == BleStatus.unsupported) {
      cards.add(
        Card(
          color: Colors.red.withOpacity(0.08),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
            side: const BorderSide(color: Colors.red),
          ),
          child: const ListTile(
            leading: Icon(Icons.block, color: Colors.red),
            title: Text(
              'Perangkat tidak mendukung BLE',
              style: TextStyle(fontWeight: FontWeight.bold),
            ),
            subtitle: Text(
              'Aplikasi ini memerlukan perangkat dengan dukungan BLE.',
            ),
          ),
        ),
      );
    }

    if (cards.isEmpty) return const SizedBox.shrink();

    return Padding(
      padding: const EdgeInsets.only(left: 12, right: 12, bottom: 4),
      child: Column(
        children:
            cards
                .map(
                  (c) => Padding(
                    padding: const EdgeInsets.only(bottom: 6),
                    child: c,
                  ),
                )
                .toList(),
      ),
    );
  }
}

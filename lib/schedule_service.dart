// lib/schedule_service.dart

import 'package:cloud_firestore/cloud_firestore.dart';

class ClassSchedule {
  final String id;
  final String classId;
  final String courseName; 
  final int dayOfWeek;
  final int startMinutes;
  final int endMinutes;
  final int earlyTolerance;
  final int lateTolerance;

  ClassSchedule({
    required this.id,
    required this.classId,
    required this.courseName,
    required this.dayOfWeek,
    required this.startMinutes,
    required this.endMinutes,
    required this.earlyTolerance,
    required this.lateTolerance,
  });

  factory ClassSchedule.fromDoc(DocumentSnapshot<Map<String, dynamic>> doc) {
    final data = doc.data()!;
    return ClassSchedule(
      id: doc.id,
      classId: data['classId'] as String,
      courseName: data['courseName'] as String? ?? 'Tanpa nama', // 👈 NEW
      dayOfWeek: data['dayOfWeek'] as int,
      startMinutes: data['startMinutes'] as int,
      endMinutes: data['endMinutes'] as int,
      earlyTolerance: data['earlyTolerance'] as int? ?? 0,
      lateTolerance: data['lateTolerance'] as int? ?? 0,
    );
  }


  bool isNowWithin(DateTime now) {
    final nowMinutes = now.hour * 60 + now.minute;
    final startWindow = startMinutes - earlyTolerance;
    final endWindow = endMinutes + lateTolerance;
    return nowMinutes >= startWindow && nowMinutes <= endWindow;
  }
}

class ScheduleService {
  static final FirebaseFirestore _db = FirebaseFirestore.instance;

  /// Cari jadwal kuliah yang AKTIF untuk classId tertentu saat ini.
  static Future<ClassSchedule?> findActiveScheduleForClass({
    required String classId,
    DateTime? now,
  }) async {
    now ??= DateTime.now();
    final dow = now.weekday; // 1..7
    final snap = await _db
        .collection('class_schedules')
        .where('classId', isEqualTo: classId)
        .where('dayOfWeek', isEqualTo: dow)
        .get();

    if (snap.docs.isEmpty) return null;

    for (final doc in snap.docs) {
      final sched = ClassSchedule.fromDoc(doc);
      if (sched.isNowWithin(now)) {
        return sched;
      }
    }
    return null;
  }
}

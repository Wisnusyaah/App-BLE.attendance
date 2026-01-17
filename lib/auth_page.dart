// lib/auth_page.dart

import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';

class AuthPage extends StatefulWidget {
  const AuthPage({super.key});

  @override
  State<AuthPage> createState() => _AuthPageState();
}

class _AuthPageState extends State<AuthPage> {
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();
  final _confirmPasswordController = TextEditingController();

  bool _isLogin = true;
  bool _isLoading = false;
  String? _errorMessage;

  static final FirebaseAuth _auth = FirebaseAuth.instance;
  static final FirebaseFirestore _db = FirebaseFirestore.instance;

  @override
  void dispose() {
    _emailController.dispose();
    _passwordController.dispose();
    _confirmPasswordController.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final email = _emailController.text.trim();
    final password = _passwordController.text.trim();
    final confirm = _confirmPasswordController.text.trim();

    if (email.isEmpty || password.isEmpty) {
      setState(() {
        _errorMessage = 'Email dan password tidak boleh kosong.';
      });
      return;
    }

    if (!_isLogin && password != confirm) {
      setState(() {
        _errorMessage = 'Konfirmasi password tidak sama.';
      });
      return;
    }

    setState(() {
      _errorMessage = null;
      _isLoading = true;
    });

    try {
      if (_isLogin) {
        await _auth.signInWithEmailAndPassword(
          email: email,
          password: password,
        );
      } else {
        final cred = await _auth.createUserWithEmailAndPassword(
          email: email,
          password: password,
        );

        // Simpan data user dasar di Firestore
        await _db.collection('users').doc(cred.user!.uid).set({
          'email': email,
          'createdAt': FieldValue.serverTimestamp(),
          'role': 'student', // nanti bisa diubah ke 'teacher' manual
        });
      }
    } on FirebaseAuthException catch (e) {
      setState(() {
        _errorMessage = e.message ?? 'Terjadi kesalahan otentikasi.';
      });
    } catch (e) {
      setState(() {
        _errorMessage = 'Error: $e';
      });
    } finally {
      if (mounted) {
        setState(() {
          _isLoading = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final isLogin = _isLogin;
    final title = isLogin ? 'Masuk' : 'Daftar akun';

    return Scaffold(
      body: SafeArea(
        child: LayoutBuilder(
          builder: (context, constraints) {
            return SingleChildScrollView(
              child: ConstrainedBox(
                constraints: BoxConstraints(minHeight: constraints.maxHeight),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    // HEADER GRADIENT
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.fromLTRB(24, 24, 24, 32),
                      decoration: const BoxDecoration(
                        gradient: LinearGradient(
                          colors: [Color(0xFF4F46E5), Color(0xFF6366F1)],
                          begin: Alignment.topLeft,
                          end: Alignment.bottomRight,
                        ),
                        borderRadius: BorderRadius.vertical(
                          bottom: Radius.circular(32),
                        ),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Icon(
                            Icons.bluetooth_audio_rounded,
                            color: Colors.white,
                            size: 40,
                          ),
                          const SizedBox(height: 16),
                          const Text(
                            'BLE Attendance',
                            style: TextStyle(
                              color: Colors.white,
                              fontSize: 24,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          const SizedBox(height: 6),
                          Text(
                            isLogin
                                ? 'Masuk untuk mulai absen otomatis ketika dekat beacon kelas.'
                                : 'Daftar sebagai mahasiswa untuk mencoba sistem absen otomatis.',
                            style: const TextStyle(
                              color: Colors.white70,
                              fontSize: 13,
                            ),
                          ),
                        ],
                      ),
                    ),

                    const SizedBox(height: 24),

                    // CARD FORM
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 24),
                      child: Card(
                        child: Padding(
                          padding: const EdgeInsets.all(20),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              // Toggle Login / Register
                              Container(
                                decoration: BoxDecoration(
                                  color: Colors.grey.shade100,
                                  borderRadius: BorderRadius.circular(999),
                                ),
                                padding: const EdgeInsets.all(4),
                                child: Row(
                                  children: [
                                    Expanded(
                                      child: ChoiceChip(
                                        selected: isLogin,
                                        onSelected: _isLoading
                                            ? null
                                            : (v) {
                                                if (!v) return;
                                                setState(() {
                                                  _isLogin = true;
                                                });
                                              },
                                        label: const Text('Masuk'),
                                        selectedColor:
                                            const Color(0xFF4F46E5),
                                        labelStyle: TextStyle(
                                          color: isLogin
                                              ? Colors.white
                                              : Colors.black87,
                                          fontWeight: FontWeight.w600,
                                        ),
                                        backgroundColor: Colors.transparent,
                                      ),
                                    ),
                                    const SizedBox(width: 4),
                                    Expanded(
                                      child: ChoiceChip(
                                        selected: !isLogin,
                                        onSelected: _isLoading
                                            ? null
                                            : (v) {
                                                if (!v) return;
                                                setState(() {
                                                  _isLogin = false;
                                                });
                                              },
                                        label: const Text('Daftar'),
                                        selectedColor:
                                            const Color(0xFF4F46E5),
                                        labelStyle: TextStyle(
                                          color: !isLogin
                                              ? Colors.white
                                              : Colors.black87,
                                          fontWeight: FontWeight.w600,
                                        ),
                                        backgroundColor: Colors.transparent,
                                      ),
                                    ),
                                  ],
                                ),
                              ),

                              const SizedBox(height: 20),
                              Text(
                                title,
                                style: const TextStyle(
                                  fontWeight: FontWeight.bold,
                                  fontSize: 18,
                                ),
                              ),
                              const SizedBox(height: 12),

                              // EMAIL
                              TextField(
                                controller: _emailController,
                                keyboardType: TextInputType.emailAddress,
                                decoration: const InputDecoration(
                                  labelText: 'Email',
                                  prefixIcon: Icon(Icons.email_outlined),
                                ),
                              ),
                              const SizedBox(height: 12),

                              // PASSWORD
                              TextField(
                                controller: _passwordController,
                                obscureText: true,
                                decoration: const InputDecoration(
                                  labelText: 'Password',
                                  prefixIcon: Icon(Icons.lock_outline),
                                ),
                              ),
                              if (!isLogin) ...[
                                const SizedBox(height: 12),
                                TextField(
                                  controller: _confirmPasswordController,
                                  obscureText: true,
                                  decoration: const InputDecoration(
                                    labelText: 'Konfirmasi password',
                                    prefixIcon: Icon(Icons.lock_outline),
                                  ),
                                ),
                              ],

                              const SizedBox(height: 12),

                              if (_errorMessage != null) ...[
                                Text(
                                  _errorMessage!,
                                  style: const TextStyle(
                                    color: Colors.red,
                                    fontSize: 12,
                                  ),
                                ),
                                const SizedBox(height: 8),
                              ],

                              SizedBox(
                                width: double.infinity,
                                child: ElevatedButton(
                                  onPressed: _isLoading ? null : _submit,
                                  child: _isLoading
                                      ? const SizedBox(
                                          height: 18,
                                          width: 18,
                                          child: CircularProgressIndicator(
                                            strokeWidth: 2,
                                            color: Colors.white,
                                          ),
                                        )
                                      : Text(isLogin ? 'Masuk' : 'Register'),
                                ),
                              ),
                              const SizedBox(height: 8),

                              TextButton(
                                onPressed: _isLoading
                                    ? null
                                    : () {
                                        setState(() {
                                          _isLogin = !_isLogin;
                                          _errorMessage = null;
                                        });
                                      },
                                child: Text(
                                  isLogin
                                      ? 'Belum punya akun? Daftar'
                                      : 'Sudah punya akun? Masuk',
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),

                    const SizedBox(height: 24),
                  ],
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}

/// Service untuk catat presensi ke Firestore.
/// Dipakai oleh auto_attendance_page & simulation page.

/// Service untuk catat presensi ke Firestore.
/// Dipakai oleh auto_attendance_page.
///
/// Skema doc (1 user per window):
/// - docId: <windowId>_<userId>
/// - checkinAt: waktu check-in (serverTimestamp)
/// - checkoutAt: waktu check-out (serverTimestamp, opsional)
class AttendanceService {
  static final FirebaseFirestore _db = FirebaseFirestore.instance;
  static final FirebaseAuth _auth = FirebaseAuth.instance;

  /// eventType:
  /// - 'checkin'
  /// - 'checkout'
  static Future<void> markAttendance({
    required String windowId,
    required String eventType,
    required String classId,
    required String scheduleId,
    required String className,
    required int major,
    required int minor,
    required String uuid,
    required String deviceId,
    required double avgRssi,
    required double avgDistance,
    String? courseName,
    String method = 'ble', // 'ble' | 'manual'
  }) async {
    final user = _auth.currentUser;
    if (user == null) throw Exception('User belum login.');

    final docId = '${windowId}_${user.uid}';
    final ref = _db.collection('attendances').doc(docId);

    await _db.runTransaction((tx) async {
      final snap = await tx.get(ref);
      final data = snap.data() ?? <String, dynamic>{};

      final hasCheckin = data['checkinAt'] != null;
      final hasCheckout = data['checkoutAt'] != null;

      if (eventType == 'checkin') {
        // Idempotent: kalau sudah checkin, tidak lakukan apa-apa.
        if (hasCheckin) return;

        tx.set(ref, {
          'windowId': windowId,
          'userId': user.uid,
          'email': user.email,
          'classId': classId,
          'scheduleId': scheduleId,
          'className': className,
          'courseName': courseName,
          'major': major,
          'minor': minor,
          'uuid': uuid,
          'deviceId': deviceId,
          'checkinAvgRssi': avgRssi,
          'checkinAvgDistance': avgDistance,
          'checkinAt': FieldValue.serverTimestamp(),
          // timestamp tetap disimpan untuk kompatibilitas query lama (berisi waktu check-in)
          'timestamp': FieldValue.serverTimestamp(),
          'method': method,
        }, SetOptions(merge: true));
        return;
      }

      if (eventType == 'checkout') {
        if (!hasCheckin) {
          throw Exception('Belum check-in. Silakan check-in dulu.');
        }
        // Idempotent: kalau sudah checkout, tidak lakukan apa-apa.
        if (hasCheckout) return;

        tx.set(ref, {
          'windowId': windowId,
          'checkoutAvgRssi': avgRssi,
          'checkoutAvgDistance': avgDistance,
          'checkoutAt': FieldValue.serverTimestamp(),
          // method jangan ditimpa kalau sebelumnya manual, dst.
        }, SetOptions(merge: true));
        return;
      }

      throw Exception('eventType tidak dikenal: $eventType');
    });
  }
}


// lib/enrollment_service.dart

import 'package:cloud_firestore/cloud_firestore.dart';

class EnrollmentService {
  static final FirebaseFirestore _db = FirebaseFirestore.instance;

  /// Cek apakah user terdaftar (enrolled) di classId tertentu.
  static Future<bool> isUserEnrolledToClass({
    required String userId,
    required String classId,
  }) async {
    final snap = await _db
        .collection('enrollments')
        .where('userId', isEqualTo: userId)
        .where('classId', isEqualTo: classId)
        .limit(1)
        .get();

    return snap.docs.isNotEmpty;
  }
}

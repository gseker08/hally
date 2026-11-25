import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api/api_client.dart';
import '../../core/auth/auth_repository.dart';

class FamilyMember {
  const FamilyMember({
    required this.userId,
    required this.displayName,
    required this.role,
    this.accessUntil,
    this.childIds = const [],
    this.canSeeHealth = true,
  });

  factory FamilyMember.fromJson(Map<String, dynamic> m) => FamilyMember(
        userId: m['userId'] as String,
        displayName: m['displayName'] as String,
        role: m['role'] as String,
        accessUntil: m['accessUntil'] == null ? null : DateTime.parse(m['accessUntil'] as String).toLocal(),
        childIds: [for (final id in m['childIds'] as List? ?? const []) id as String],
        canSeeHealth: m['canSeeHealth'] as bool? ?? true,
      );

  final String userId;
  final String displayName;

  /// Owner or Adult (parents, equal rights) or Caregiver.
  final String role;

  /// Caregivers: when access ends (null = until a parent removes them).
  final DateTime? accessUntil;

  /// Caregivers: the children they look after; empty means all.
  final List<String> childIds;

  /// Caregivers: may read the health card. Always true for parents.
  final bool canSeeHealth;

  bool get isCaregiver => role == 'Caregiver';
}

/// What a caregiver can reach. Null [until] = no end; empty [childIds] = every child.
class CaregiverAccess {
  const CaregiverAccess({this.until, this.childIds = const [], this.canSeeHealth = false});

  final DateTime? until;
  final List<String> childIds;
  final bool canSeeHealth;

  Map<String, dynamic> toJson() => {
        'accessUntil': until?.toUtc().toIso8601String(),
        'childIds': childIds,
        'canSeeHealth': canSeeHealth,
      };
}

/// A child profile: first name only, an optional birth year, a colour key (see `childColor`) and an optional photo.
class ChildProfile {
  const ChildProfile({required this.id, required this.firstName, this.birthYear, this.color = 'sky', this.photoUrl});

  factory ChildProfile.fromJson(Map<String, dynamic> j) => ChildProfile(
        id: j['id'] as String,
        firstName: j['firstName'] as String,
        birthYear: j['birthYear'] as int?,
        color: j['color'] as String? ?? 'sky',
        photoUrl: j['photoUrl'] as String?,
      );

  final String id;
  final String firstName;
  final int? birthYear;
  final String color;

  /// Relative API path of the profile photo; it changes whenever the photo does. Null shows the initial.
  final String? photoUrl;
}

class FamilyDetails {
  const FamilyDetails({required this.id, required this.name, required this.timeZoneId, required this.members, this.children = const []});

  factory FamilyDetails.fromJson(Map<String, dynamic> json) => FamilyDetails(
        id: json['id'] as String,
        name: json['name'] as String,
        timeZoneId: json['timeZoneId'] as String,
        members: [
          for (final m in json['members'] as List) FamilyMember.fromJson(m as Map<String, dynamic>),
        ],
        children: [for (final c in json['children'] as List? ?? const []) ChildProfile.fromJson(c as Map<String, dynamic>)],
      );

  final String id;
  final String name;
  final String timeZoneId;
  final List<FamilyMember> members;
  final List<ChildProfile> children;
}

class Invitation {
  const Invitation({required this.url, required this.shareText, required this.whatsAppUrl});

  final String url;
  final String shareText;
  final String whatsAppUrl;
}

class InvitationPreview {
  const InvitationPreview({required this.familyName, required this.invitedBy, required this.status, this.role = 'parent'});

  final String familyName;
  final String invitedBy;
  final String status;

  /// "parent" or "caregiver".
  final String role;

  bool get isPending => status == 'pending';
}

abstract interface class FamilyRepository {
  Future<FamilyDetails> create(String name, String timeZoneId);
  Future<FamilyDetails> get(String familyId);
  /// Invites a parent, or a caregiver when [caregiver] is given.
  Future<Invitation> invite(String familyId, {CaregiverAccess? caregiver});

  /// Changes a caregiver's end date, children and health permission. Parents only.
  Future<FamilyMember> setCaregiverAccess(String familyId, String userId, CaregiverAccess access);

  /// Removes a caregiver from the family right away. Parents only.
  Future<void> removeCaregiver(String familyId, String userId);
  Future<InvitationPreview> preview(String token);
  Future<String> accept(String token);
  Future<ChildProfile> addChild(String familyId, {required String firstName, int? birthYear, String? color});
  Future<ChildProfile> updateChild(String familyId, String childId, {required String firstName, int? birthYear, required String color});
  Future<void> deleteChild(String familyId, String childId);
  Future<ChildProfile> setChildPhoto(String familyId, String childId, Uint8List bytes);
  Future<ChildProfile> deleteChildPhoto(String familyId, String childId);

  /// Downloads a photo from [ChildProfile.photoUrl].
  Future<Uint8List> childPhoto(String photoUrl);
}

class ApiFamilyRepository implements FamilyRepository {
  ApiFamilyRepository(this._api);

  final ApiClient _api;

  Future<T> _call<T>(Future<T> Function() fn) async {
    try {
      return await fn();
    } catch (e) {
      throw ApiClient.toApiException(e);
    }
  }

  @override
  Future<FamilyDetails> create(String name, String timeZoneId) => _call(() async {
        final res = await _api.dio.post<Map<String, dynamic>>('/api/v1/families', data: {'name': name, 'timeZoneId': timeZoneId});
        return FamilyDetails.fromJson(res.data!);
      });

  @override
  Future<FamilyDetails> get(String familyId) => _call(() async {
        final res = await _api.dio.get<Map<String, dynamic>>('/api/v1/families/$familyId');
        return FamilyDetails.fromJson(res.data!);
      });

  @override
  Future<Invitation> invite(String familyId, {CaregiverAccess? caregiver}) => _call(() async {
        final res = await _api.dio.post<Map<String, dynamic>>('/api/v1/families/$familyId/invitations',
            data: caregiver == null ? null : {'role': 'caregiver', ...caregiver.toJson()});
        final d = res.data!;
        return Invitation(url: d['url'] as String, shareText: d['shareText'] as String, whatsAppUrl: d['whatsAppUrl'] as String);
      });

  @override
  Future<InvitationPreview> preview(String token) => _call(() async {
        final res = await _api.dio.get<Map<String, dynamic>>('/api/v1/invitations/$token');
        final d = res.data!;
        return InvitationPreview(
          familyName: d['familyName'] as String,
          invitedBy: d['invitedBy'] as String,
          status: d['status'] as String,
          role: d['role'] as String? ?? 'parent',
        );
      });

  @override
  Future<FamilyMember> setCaregiverAccess(String familyId, String userId, CaregiverAccess access) => _call(() async {
        final res = await _api.dio.put<Map<String, dynamic>>('/api/v1/families/$familyId/members/$userId/access', data: access.toJson());
        return FamilyMember.fromJson(res.data!);
      });

  @override
  Future<void> removeCaregiver(String familyId, String userId) =>
      _call(() => _api.dio.delete<dynamic>('/api/v1/families/$familyId/members/$userId'));

  @override
  Future<String> accept(String token) => _call(() async {
        final res = await _api.dio.post<Map<String, dynamic>>('/api/v1/invitations/$token/accept');
        return res.data!['familyId'] as String;
      });

  @override
  Future<ChildProfile> addChild(String familyId, {required String firstName, int? birthYear, String? color}) => _call(() async {
        final res = await _api.dio.post<Map<String, dynamic>>('/api/v1/families/$familyId/children',
            data: {'firstName': firstName, 'birthYear': birthYear, 'color': color});
        return ChildProfile.fromJson(res.data!);
      });

  @override
  Future<ChildProfile> updateChild(String familyId, String childId, {required String firstName, int? birthYear, required String color}) =>
      _call(() async {
        final res = await _api.dio.put<Map<String, dynamic>>('/api/v1/families/$familyId/children/$childId',
            data: {'firstName': firstName, 'birthYear': birthYear, 'color': color});
        return ChildProfile.fromJson(res.data!);
      });

  @override
  Future<void> deleteChild(String familyId, String childId) =>
      _call(() => _api.dio.delete<dynamic>('/api/v1/families/$familyId/children/$childId'));

  @override
  Future<ChildProfile> setChildPhoto(String familyId, String childId, Uint8List bytes) => _call(() async {
        final res = await _api.dio.put<Map<String, dynamic>>('/api/v1/families/$familyId/children/$childId/photo',
            data: FormData.fromMap({'file': MultipartFile.fromBytes(bytes, filename: 'child.png', contentType: DioMediaType.parse('image/png'))}));
        return ChildProfile.fromJson(res.data!);
      });

  @override
  Future<ChildProfile> deleteChildPhoto(String familyId, String childId) => _call(() async {
        final res = await _api.dio.delete<Map<String, dynamic>>('/api/v1/families/$familyId/children/$childId/photo');
        return ChildProfile.fromJson(res.data!);
      });

  @override
  Future<Uint8List> childPhoto(String photoUrl) => _call(() async {
        final res = await _api.dio.get<List<int>>(photoUrl, options: Options(responseType: ResponseType.bytes));
        return Uint8List.fromList(res.data!);
      });
}

final familyRepositoryProvider = Provider<FamilyRepository>((ref) => ApiFamilyRepository(ref.watch(apiClientProvider)));

final familyProvider = FutureProvider.family<FamilyDetails, String>((ref, id) => ref.watch(familyRepositoryProvider).get(id));

/// True when the signed-in person is a caregiver in their family: parent-only actions are hidden then.
/// Parents (mother, father) have equal rights.
final isCaregiverProvider = Provider<bool>((ref) => ref.watch(meProvider).valueOrNull?.primaryFamily?.isCaregiver ?? false);

/// Whether the signed-in person may read the health card: parents always, caregivers when a parent allowed it.
final canSeeHealthProvider = Provider<bool>((ref) {
  final me = ref.watch(meProvider).valueOrNull;
  final family = me?.primaryFamily;
  if (family == null || !family.isCaregiver) return true;
  final details = ref.watch(familyProvider(family.id)).valueOrNull;
  return details?.members.where((m) => m.userId == me!.id).firstOrNull?.canSeeHealth ?? false;
});

/// A child's photo by its URL. Kept for the session: the URL changes when the photo does, so it never goes stale.
final childPhotoProvider = FutureProvider.family<Uint8List, String>((ref, url) => ref.watch(familyRepositoryProvider).childPhoto(url));

/// Extracts the token from a pasted invite link (https://…/i/{token}) or a bare token.
String parseInviteToken(String input) {
  final trimmed = input.trim();
  final uri = Uri.tryParse(trimmed);
  if (uri != null && uri.pathSegments.length >= 2 && uri.pathSegments[uri.pathSegments.length - 2] == 'i') {
    return uri.pathSegments.last;
  }
  return trimmed;
}

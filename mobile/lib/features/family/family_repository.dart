import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api/api_client.dart';

class FamilyMember {
  const FamilyMember({required this.userId, required this.displayName, required this.role});

  final String userId;
  final String displayName;
  final String role;
}

/// A child profile: first name only, an optional birth year and a colour key (see `childColor`).
class ChildProfile {
  const ChildProfile({required this.id, required this.firstName, this.birthYear, this.color = 'sky'});

  factory ChildProfile.fromJson(Map<String, dynamic> j) => ChildProfile(
        id: j['id'] as String,
        firstName: j['firstName'] as String,
        birthYear: j['birthYear'] as int?,
        color: j['color'] as String? ?? 'sky',
      );

  final String id;
  final String firstName;
  final int? birthYear;
  final String color;
}

class FamilyDetails {
  const FamilyDetails({required this.id, required this.name, required this.timeZoneId, required this.members, this.children = const []});

  factory FamilyDetails.fromJson(Map<String, dynamic> json) => FamilyDetails(
        id: json['id'] as String,
        name: json['name'] as String,
        timeZoneId: json['timeZoneId'] as String,
        members: [
          for (final m in json['members'] as List)
            FamilyMember(userId: m['userId'] as String, displayName: m['displayName'] as String, role: m['role'] as String),
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
  const InvitationPreview({required this.familyName, required this.invitedBy, required this.status});

  final String familyName;
  final String invitedBy;
  final String status;

  bool get isPending => status == 'pending';
}

abstract interface class FamilyRepository {
  Future<FamilyDetails> create(String name, String timeZoneId);
  Future<FamilyDetails> get(String familyId);
  Future<Invitation> invite(String familyId);
  Future<InvitationPreview> preview(String token);
  Future<String> accept(String token);
  Future<ChildProfile> addChild(String familyId, {required String firstName, int? birthYear, String? color});
  Future<ChildProfile> updateChild(String familyId, String childId, {required String firstName, int? birthYear, required String color});
  Future<void> deleteChild(String familyId, String childId);
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
  Future<Invitation> invite(String familyId) => _call(() async {
        final res = await _api.dio.post<Map<String, dynamic>>('/api/v1/families/$familyId/invitations');
        final d = res.data!;
        return Invitation(url: d['url'] as String, shareText: d['shareText'] as String, whatsAppUrl: d['whatsAppUrl'] as String);
      });

  @override
  Future<InvitationPreview> preview(String token) => _call(() async {
        final res = await _api.dio.get<Map<String, dynamic>>('/api/v1/invitations/$token');
        final d = res.data!;
        return InvitationPreview(familyName: d['familyName'] as String, invitedBy: d['invitedBy'] as String, status: d['status'] as String);
      });

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
}

final familyRepositoryProvider = Provider<FamilyRepository>((ref) => ApiFamilyRepository(ref.watch(apiClientProvider)));

final familyProvider = FutureProvider.family<FamilyDetails, String>((ref, id) => ref.watch(familyRepositoryProvider).get(id));

/// Extracts the token from a pasted invite link (https://…/i/{token}) or a bare token.
String parseInviteToken(String input) {
  final trimmed = input.trim();
  final uri = Uri.tryParse(trimmed);
  if (uri != null && uri.pathSegments.length >= 2 && uri.pathSegments[uri.pathSegments.length - 2] == 'i') {
    return uri.pathSegments.last;
  }
  return trimmed;
}

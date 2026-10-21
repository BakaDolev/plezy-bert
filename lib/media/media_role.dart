import 'package:json_annotation/json_annotation.dart';

import '../utils/json_utils.dart';

part 'media_role.g.dart';

/// A cast or crew member attached to a media item.
@JsonSerializable(includeIfNull: false)
class MediaRole {
  final String? id;
  @JsonKey(fromJson: stringOrEmpty)
  final String tag;
  final String? role;
  final String? thumbPath;

  /// Plex's global person key for this cast/crew member (`Role.tagKey`, e.g.
  /// `5d776824...`). Stable across every title the person appears in — unlike
  /// [id], which is a per-title credit id — so it is the bridge to Plex's
  /// online metadata provider (full filmography, "Known For"). Null on
  /// backends/rows that don't expose it.
  final String? tagKey;

  const MediaRole({this.id, required this.tag, this.role, this.thumbPath, this.tagKey});

  factory MediaRole.fromJson(Map<String, dynamic> json) => _$MediaRoleFromJson(json);

  Map<String, dynamic> toJson() => _$MediaRoleToJson(this);
}

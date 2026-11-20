import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../data/models.dart';
import '../state/app_state.dart';
import '../theme/apple_design.dart';
import 'catalog_links.dart';

/// One entry of the shared track menu.
enum TrackMenuAction {
  playNow,
  playNext,
  enqueue,
  toggleLike,
  openAlbum,
  openArtist,
  copyLink,
  removeFromQueue,
}

/// Shows the shared secondary-click menu for [track].
///
/// Every list in the app offers the same queue and metadata actions through
/// here; only "play now" and "remove from queue" depend on the list the row
/// lives in, so those arrive as [onPlayNow] / [queueIndex]. Actions the data
/// cannot support (no album id, no artist, guest session) stay in the menu but
/// disabled, so the list of entries never shifts between rows.
Future<void> showTrackContextMenu({
  required BuildContext context,
  required AppState state,
  required Track track,
  required Offset position,
  required VoidCallback onPlayNow,
  int? queueIndex,
}) async {
  final RenderBox overlay =
      Overlay.of(context).context.findRenderObject()! as RenderBox;
  final bool liked = state.isLiked(track);
  final TrackMenuAction? action = await showMenu<TrackMenuAction>(
    context: context,
    position: RelativeRect.fromLTRB(
      position.dx,
      position.dy,
      overlay.size.width - position.dx,
      overlay.size.height - position.dy,
    ),
    items: <PopupMenuEntry<TrackMenuAction>>[
      _entry(context, TrackMenuAction.playNow, '立即播放'),
      _entry(context, TrackMenuAction.playNext, '下一首播放'),
      _entry(context, TrackMenuAction.enqueue, '添加到队列'),
      const PopupMenuDivider(height: 9),
      _entry(
        context,
        TrackMenuAction.toggleLike,
        liked ? '取消收藏' : '收藏',
        enabled: state.signedIn,
      ),
      const PopupMenuDivider(height: 9),
      _entry(
        context,
        TrackMenuAction.openAlbum,
        '查看专辑',
        enabled: track.albumId > 0 && track.album.trim().isNotEmpty,
      ),
      _entry(
        context,
        TrackMenuAction.openArtist,
        '查看歌手',
        enabled: track.artists.any((ArtistRef artist) => artist.id > 0),
      ),
      const PopupMenuDivider(height: 9),
      _entry(context, TrackMenuAction.copyLink, '复制链接'),
      if (queueIndex != null) ...<PopupMenuEntry<TrackMenuAction>>[
        const PopupMenuDivider(height: 9),
        _entry(
          context,
          TrackMenuAction.removeFromQueue,
          '从队列移除',
          enabled: queueIndex > state.queueIndex,
        ),
      ],
    ],
  );
  if (action == null || !context.mounted) return;
  switch (action) {
    case TrackMenuAction.playNow:
      onPlayNow();
    case TrackMenuAction.playNext:
      final bool started = state.queueNext(track);
      _snack(context, started ? '正在播放' : '将在下一首播放');
    case TrackMenuAction.enqueue:
      final bool started = state.enqueueTrack(track);
      _snack(context, started ? '正在播放' : '已添加到队列');
    case TrackMenuAction.toggleLike:
      unawaited(state.toggleLike(track));
    case TrackMenuAction.openAlbum:
      unawaited(openAlbumDetails(context, state, _stubAlbum(track)));
    case TrackMenuAction.openArtist:
      unawaited(openArtists(context, state, track.artists));
    case TrackMenuAction.copyLink:
      await Clipboard.setData(
        ClipboardData(text: 'https://music.163.com/song?id=${track.id}'),
      );
      if (context.mounted) _snack(context, '已复制链接');
    case TrackMenuAction.removeFromQueue:
      if (queueIndex != null && state.removeQueuedAt(queueIndex)) {
        _snack(context, '已从队列移除');
      }
  }
}

PopupMenuItem<TrackMenuAction> _entry(
  BuildContext context,
  TrackMenuAction value,
  String label, {
  bool enabled = true,
}) {
  final AppleSemanticColors apple = AppleSemanticColors.of(context);
  return PopupMenuItem<TrackMenuAction>(
    value: value,
    enabled: enabled,
    height: 36,
    padding: const EdgeInsets.symmetric(horizontal: 14),
    child: SizedBox(
      width: 176,
      child: Text(
        label,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
          color: enabled ? apple.label : apple.tertiaryLabel,
        ),
      ),
    ),
  );
}

/// A listed track only knows its album id; the album page loads the full
/// description from that id, so this stub is enough to open it.
Album _stubAlbum(Track track) => Album(
  id: '${track.albumId}',
  title: track.album,
  artist: track.artist,
  year: '',
  coverSeed: track.coverSeed,
  note: '',
  accent: track.accent,
  coverUrl: track.coverUrl,
  artists: track.artists,
);

void _snack(BuildContext context, String message) {
  ScaffoldMessenger.of(context)
    ..removeCurrentSnackBar()
    ..showSnackBar(
      SnackBar(
        content: Text(message),
        behavior: SnackBarBehavior.floating,
        duration: const Duration(seconds: 2),
      ),
    );
}

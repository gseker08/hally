import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';

import '../../core/design/tokens.dart';
import '../../l10n/gen/app_localizations.dart';
import 'messages_repository.dart';

/// A photo picked for sending: the bytes plus what the upload needs.
class PickedPhoto {
  const PickedPhoto({required this.bytes, required this.fileName, required this.contentType});

  final Uint8List bytes;
  final String fileName;
  final String contentType;

  static String contentTypeOf(String fileName) {
    final name = fileName.toLowerCase();
    if (name.endsWith('.png')) return 'image/png';
    if (name.endsWith('.webp')) return 'image/webp';
    if (name.endsWith('.heic') || name.endsWith('.heif')) return 'image/heic';
    return 'image/jpeg';
  }
}

/// Picks a photo from the camera or gallery. Shrunk on the phone (1600 px, quality 80) so it uploads quickly.
typedef PhotoPicker = Future<PickedPhoto?> Function(ImageSource source);

Future<PickedPhoto?> pickChatPhoto(ImageSource source) async {
  final file = await ImagePicker().pickImage(source: source, maxWidth: 1600, maxHeight: 1600, imageQuality: 80);
  if (file == null) return null;
  return PickedPhoto(bytes: await file.readAsBytes(), fileName: file.name, contentType: PickedPhoto.contentTypeOf(file.name));
}

/// Overridden in tests, where there is no camera or gallery.
final photoPickerProvider = Provider<PhotoPicker>((ref) => pickChatPhoto);

/// Asks camera or gallery.
Future<ImageSource?> askPhotoSource(BuildContext context) {
  final l10n = AppLocalizations.of(context);
  return showModalBottomSheet<ImageSource>(
    context: context,
    useRootNavigator: true,
    showDragHandle: true,
    builder: (context) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ListTile(
            key: const Key('chat.photo.camera'),
            leading: const Icon(Icons.photo_camera_rounded),
            title: Text(l10n.chatPhotoCamera),
            onTap: () => Navigator.of(context).pop(ImageSource.camera),
          ),
          ListTile(
            key: const Key('chat.photo.gallery'),
            leading: const Icon(Icons.photo_library_rounded),
            title: Text(l10n.chatPhotoGallery),
            onTap: () => Navigator.of(context).pop(ImageSource.gallery),
          ),
          const SizedBox(height: HallySpace.sm),
        ],
      ),
    ),
  );
}

/// Full-screen preview before sending, with an optional caption. Returns the caption (possibly empty) to send, or
/// null when cancelled.
class PhotoPreviewPage extends StatefulWidget {
  const PhotoPreviewPage({super.key, required this.photo, this.caption = ''});

  final PickedPhoto photo;
  final String caption;

  @override
  State<PhotoPreviewPage> createState() => _PhotoPreviewPageState();
}

class _PhotoPreviewPageState extends State<PhotoPreviewPage> {
  late final _caption = TextEditingController(text: widget.caption);

  @override
  void dispose() {
    _caption.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: Text(l10n.chatPhotoPreview),
      ),
      body: Column(
        children: [
          Expanded(
            child: InteractiveViewer(
              child: Center(
                child: Image.memory(widget.photo.bytes, key: const Key('chat.photo.preview'), fit: BoxFit.contain,
                    errorBuilder: (_, __, ___) => const Icon(Icons.image_rounded, color: Colors.white54, size: 64)),
              ),
            ),
          ),
          SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(HallySpace.md, HallySpace.sm, HallySpace.sm, HallySpace.sm),
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      key: const Key('chat.photo.caption'),
                      controller: _caption,
                      minLines: 1,
                      maxLines: 4,
                      maxLength: 2000,
                      textCapitalization: TextCapitalization.sentences,
                      style: const TextStyle(color: Colors.white),
                      decoration: InputDecoration(
                        hintText: l10n.chatPhotoCaptionHint,
                        hintStyle: const TextStyle(color: Colors.white60),
                        counterText: '',
                        filled: true,
                        fillColor: Colors.white12,
                      ),
                    ),
                  ),
                  const SizedBox(width: HallySpace.xs),
                  IconButton.filled(
                    key: const Key('chat.photo.send'),
                    tooltip: l10n.chatSend,
                    onPressed: () => Navigator.of(context).pop(_caption.text.trim()),
                    icon: const Icon(Icons.send_rounded),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// A message's photo inside its bubble. Tapping opens it full screen.
class ChatPhoto extends ConsumerStatefulWidget {
  const ChatPhoto({super.key, required this.familyId, required this.chatKey, required this.messageId});

  final String familyId;
  final String chatKey;
  final String messageId;

  @override
  ConsumerState<ChatPhoto> createState() => _ChatPhotoState();
}

class _ChatPhotoState extends ConsumerState<ChatPhoto> {
  late Future<Uint8List> _bytes = _load();

  Future<Uint8List> _load() => ref.read(messagesRepositoryProvider).photo(widget.familyId, widget.chatKey, widget.messageId);

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    return ClipRRect(
      borderRadius: BorderRadius.circular(14),
      child: FutureBuilder<Uint8List>(
        future: _bytes,
        builder: (context, snap) {
          if (snap.hasData && snap.data!.isNotEmpty) {
            final bytes = snap.data!;
            return GestureDetector(
              key: Key('chat.photo.${widget.messageId}'),
              onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(
                fullscreenDialog: true,
                builder: (_) => PhotoViewerPage(bytes: bytes, tag: widget.messageId),
              )),
              child: Hero(
                tag: widget.messageId,
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxHeight: 280, minWidth: 120, minHeight: 80),
                  child: Image.memory(bytes, fit: BoxFit.cover, gaplessPlayback: true,
                      semanticLabel: l10n.chatPhoto,
                      errorBuilder: (_, __, ___) => _placeholder(theme, Icons.broken_image_rounded)),
                ),
              ),
            );
          }
          if (snap.hasError) {
            return InkWell(
              key: Key('chat.photo.${widget.messageId}.retry'),
              onTap: () => setState(() => _bytes = _load()),
              child: _placeholder(theme, Icons.refresh_rounded, label: l10n.chatPhotoRetry),
            );
          }
          return _placeholder(theme, null);
        },
      ),
    );
  }

  Widget _placeholder(ThemeData theme, IconData? icon, {String? label}) => Container(
        width: 200,
        height: 160,
        color: theme.colorScheme.surfaceContainer,
        alignment: Alignment.center,
        child: icon == null
            ? const SizedBox(width: 24, height: 24, child: CircularProgressIndicator(strokeWidth: 2))
            : Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(icon, color: theme.colorScheme.onSurfaceVariant),
                  if (label != null) Text(label, style: theme.textTheme.labelMedium),
                ],
              ),
      );
}

/// Full-screen photo with pinch to zoom.
class PhotoViewerPage extends StatelessWidget {
  const PhotoViewerPage({super.key, required this.bytes, required this.tag});

  final Uint8List bytes;
  final String tag;

  @override
  Widget build(BuildContext context) => Scaffold(
        backgroundColor: Colors.black,
        appBar: AppBar(backgroundColor: Colors.black, foregroundColor: Colors.white),
        body: InteractiveViewer(
          key: const Key('chat.photo.viewer'),
          maxScale: 5,
          child: Center(child: Hero(tag: tag, child: Image.memory(bytes, fit: BoxFit.contain))),
        ),
      );
}

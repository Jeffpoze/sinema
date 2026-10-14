import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'services/jellyfin_api_service.dart';
import 'widgets/sinema_image.dart';

String? _asString(dynamic value) => value is String ? value : null;
int? _asInt(dynamic value) => value is num ? value.toInt() : null;
num? _asNum(dynamic value) => value is num ? value : null;

// Real, functional Jellyfin admin actions grouped behind one entry point
// (matches how third-party clients like Infuse group these), rather than
// scattering Edit Metadata / Delete / etc. directly in the main action
// sheet where a non-admin item never appears anyway.
class ManageScreen extends StatefulWidget {
  const ManageScreen({super.key, required this.serverUrl, required this.userId, required this.token, required this.itemId, required this.itemName});
  final String serverUrl;
  final String userId;
  final String token;
  final String itemId;
  final String itemName;

  @override
  State<ManageScreen> createState() => _ManageScreenState();
}

class _ManageScreenState extends State<ManageScreen> {
  final _api = JellyfinApiService();

  Future<void> _refresh() async {
    try {
      await _api.refreshMetadata(widget.serverUrl, widget.token, widget.itemId);
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Refreshing metadata…')));
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Could not refresh: $e')));
    }
  }

  Future<void> _confirmDelete() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete from server?'),
        content: Text('This permanently deletes "${widget.itemName}" from your Jellyfin library. This cannot be undone.'),
        actions: [
          TextButton(onPressed: () => Navigator.of(context).pop(false), child: const Text('Cancel')),
          TextButton(onPressed: () => Navigator.of(context).pop(true), child: const Text('Delete', style: TextStyle(color: Colors.red))),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      await _api.deleteItem(widget.serverUrl, widget.token, widget.itemId);
      if (mounted) Navigator.of(context).pop(true);
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Could not delete: $e')));
    }
  }

  Future<void> _showPlayHistory() async {
    Map<String, dynamic>? item;
    try {
      item = await _api.getItemDetail(widget.serverUrl, widget.userId, widget.token, widget.itemId);
    } catch (_) {}
    if (!mounted) return;
    final userData = item?['UserData'] as Map<String, dynamic>?;
    final dateCreated = _asString(item?['DateCreated']);
    final lastPlayed = _asString(userData?['LastPlayedDate']);
    final playCount = _asInt(userData?['PlayCount']);
    String formatDate(String? iso) {
      if (iso == null) return 'Unknown';
      final parsed = DateTime.tryParse(iso);
      if (parsed == null) return iso;
      final local = parsed.toLocal();
      return '${local.year}-${local.month.toString().padLeft(2, '0')}-${local.day.toString().padLeft(2, '0')}';
    }
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Play History'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _InfoLine('Added to library', formatDate(dateCreated)),
            _InfoLine('Last played', lastPlayed == null ? 'Never' : formatDate(lastPlayed)),
            _InfoLine('Play count', '${playCount ?? 0}'),
          ],
        ),
        actions: [TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Close'))],
      ),
    );
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: const Color(0xFF0A0B0D),
    appBar: AppBar(
      backgroundColor: const Color(0xFF0A0B0D),
      leading: IconButton(icon: const Icon(Icons.close), onPressed: () => Navigator.of(context).pop(false)),
      title: Text(widget.itemName, style: const TextStyle(fontWeight: FontWeight.w700)),
      centerTitle: true,
    ),
    body: ListView(
      children: [
        _ManageRow(
          icon: Icons.edit_outlined,
          label: 'Edit Metadata',
          onTap: () async {
            final changed = await Navigator.of(context).push<bool>(MaterialPageRoute(
              builder: (_) => EditMetadataScreen(serverUrl: widget.serverUrl, userId: widget.userId, token: widget.token, itemId: widget.itemId, itemName: widget.itemName),
            ));
            if (changed == true && mounted) setState(() {});
          },
        ),
        _ManageRow(
          icon: Icons.local_offer_outlined,
          label: 'Edit Tags',
          onTap: () => Navigator.of(context).push(MaterialPageRoute(
            builder: (_) => EditTagsScreen(serverUrl: widget.serverUrl, userId: widget.userId, token: widget.token, itemId: widget.itemId, itemName: widget.itemName),
          )),
        ),
        _ManageRow(
          icon: Icons.image_outlined,
          label: 'Change Artwork',
          onTap: () => Navigator.of(context).push(MaterialPageRoute(
            builder: (_) => ChangeArtworkScreen(serverUrl: widget.serverUrl, token: widget.token, itemId: widget.itemId, itemName: widget.itemName),
          )),
        ),
        _ManageRow(icon: Icons.search, label: 'Analyze', onTap: _refresh),
        _ManageRow(icon: Icons.history, label: 'Play History', onTap: _showPlayHistory),
        _ManageRow(
          icon: Icons.info_outline,
          label: 'File Info',
          onTap: () => Navigator.of(context).push(MaterialPageRoute(
            builder: (_) => FileInfoScreen(serverUrl: widget.serverUrl, userId: widget.userId, token: widget.token, itemId: widget.itemId, itemName: widget.itemName),
          )),
        ),
        _ManageRow(icon: Icons.delete_outline, label: 'Delete', destructive: true, onTap: _confirmDelete),
      ],
    ),
  );
}

class _ManageRow extends StatelessWidget {
  const _ManageRow({required this.icon, required this.label, required this.onTap, this.destructive = false});
  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final bool destructive;

  @override
  Widget build(BuildContext context) => ListTile(
    leading: Icon(icon, color: destructive ? Colors.red : Colors.white),
    title: Text(label, style: TextStyle(fontSize: 16, color: destructive ? Colors.red : Colors.white)),
    onTap: onTap,
  );
}

class _InfoLine extends StatelessWidget {
  const _InfoLine(this.label, this.value);
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 4),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: const TextStyle(fontSize: 12, color: Color(0xFFA5A7AC))),
        Text(value, style: const TextStyle(fontSize: 14)),
      ],
    ),
  );
}

// ---------------------------------------------------------------------------
// Edit Metadata
// ---------------------------------------------------------------------------

class EditMetadataScreen extends StatefulWidget {
  const EditMetadataScreen({super.key, required this.serverUrl, required this.userId, required this.token, required this.itemId, required this.itemName});
  final String serverUrl;
  final String userId;
  final String token;
  final String itemId;
  final String itemName;

  @override
  State<EditMetadataScreen> createState() => _EditMetadataScreenState();
}

class _EditMetadataScreenState extends State<EditMetadataScreen> {
  final _api = JellyfinApiService();
  Map<String, dynamic>? _fullItem;
  bool _loading = true;
  bool _saving = false;
  String? _error;
  final _title = TextEditingController();
  final _sortTitle = TextEditingController();
  final _originalTitle = TextEditingController();
  final _releaseDate = TextEditingController();
  final _contentRating = TextEditingController();
  final _summary = TextEditingController();
  Set<String> _lockedFields = {};

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final item = await _api.getItemForEdit(widget.serverUrl, widget.userId, widget.token, widget.itemId);
      _fullItem = item;
      _title.text = _asString(item['Name']) ?? '';
      _sortTitle.text = _asString(item['SortName']) ?? '';
      _originalTitle.text = _asString(item['OriginalTitle']) ?? '';
      _releaseDate.text = (_asString(item['PremiereDate']) ?? '').split('T').first;
      _contentRating.text = _asString(item['OfficialRating']) ?? '';
      _summary.text = _asString(item['Overview']) ?? '';
      _lockedFields = (item['LockedFields'] as List<dynamic>?)?.whereType<String>().toSet() ?? {};
    } catch (e) {
      _error = 'Could not load metadata: $e';
    }
    if (mounted) setState(() => _loading = false);
  }

  void _toggleLock(String field) => setState(() {
    if (_lockedFields.contains(field)) {
      _lockedFields.remove(field);
    } else {
      _lockedFields.add(field);
    }
  });

  Future<void> _save() async {
    final item = _fullItem;
    if (item == null) return;
    setState(() => _saving = true);
    item['Name'] = _title.text.trim();
    item['SortName'] = _sortTitle.text.trim();
    item['OriginalTitle'] = _originalTitle.text.trim();
    final dateText = _releaseDate.text.trim();
    item['PremiereDate'] = dateText.isEmpty ? null : '${dateText}T00:00:00.000Z';
    item['OfficialRating'] = _contentRating.text.trim();
    item['Overview'] = _summary.text.trim();
    item['LockedFields'] = _lockedFields.toList();
    try {
      await _api.updateItemMetadata(widget.serverUrl, widget.token, widget.itemId, item);
      if (mounted) Navigator.of(context).pop(true);
    } catch (e) {
      if (mounted) {
        setState(() => _saving = false);
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Could not save: $e')));
      }
    }
  }

  @override
  void dispose() {
    _title.dispose();
    _sortTitle.dispose();
    _originalTitle.dispose();
    _releaseDate.dispose();
    _contentRating.dispose();
    _summary.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: const Color(0xFF0A0B0D),
    appBar: AppBar(
      backgroundColor: const Color(0xFF0A0B0D),
      leading: IconButton(icon: const Icon(Icons.arrow_back_ios_new), onPressed: () => Navigator.of(context).pop(false)),
      title: Column(children: [Text(widget.itemName, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 16)), const Text('Edit Metadata', style: TextStyle(fontSize: 12, color: Color(0xFFA5A7AC)))]),
      centerTitle: true,
      actions: [if (!_loading && _error == null) TextButton(onPressed: _saving ? null : _save, child: const Text('Save'))],
    ),
    body: _loading
        ? const Center(child: CircularProgressIndicator())
        : _error != null
            ? Center(child: Padding(padding: const EdgeInsets.all(24), child: Text(_error!, style: const TextStyle(color: Color(0xFFA5A7AC)))))
            : ListView(
                padding: const EdgeInsets.all(20),
                children: [
                  _EditField(label: 'Title', controller: _title, locked: _lockedFields.contains('Name'), onToggleLock: () => _toggleLock('Name')),
                  _EditField(label: 'Sort Title', controller: _sortTitle),
                  _EditField(label: 'Original Title', controller: _originalTitle),
                  _EditField(label: 'Original Release Date (YYYY-MM-DD)', controller: _releaseDate),
                  _EditField(label: 'Content Rating', controller: _contentRating, locked: _lockedFields.contains('OfficialRating'), onToggleLock: () => _toggleLock('OfficialRating')),
                  _EditField(label: 'Summary', controller: _summary, maxLines: 5, locked: _lockedFields.contains('Overview'), onToggleLock: () => _toggleLock('Overview')),
                ],
              ),
  );
}

class _EditField extends StatelessWidget {
  const _EditField({required this.label, required this.controller, this.maxLines = 1, this.locked, this.onToggleLock});
  final String label;
  final TextEditingController controller;
  final int maxLines;
  final bool? locked;
  final VoidCallback? onToggleLock;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 22),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(children: [
          Text(label, style: const TextStyle(fontWeight: FontWeight.w700, color: Color(0xFFCBCCD0))),
          if (locked != null) ...[
            const SizedBox(width: 8),
            GestureDetector(
              onTap: onToggleLock,
              child: Icon(locked! ? Icons.lock : Icons.lock_open, size: 16, color: const Color(0xFF808084)),
            ),
          ],
        ]),
        const SizedBox(height: 8),
        TextField(
          controller: controller,
          maxLines: maxLines,
          style: const TextStyle(color: Colors.white),
          decoration: InputDecoration(
            filled: true,
            fillColor: const Color(0xFF1B1D22),
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: BorderSide.none),
            contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          ),
        ),
      ],
    ),
  );
}

// ---------------------------------------------------------------------------
// Edit Tags (Writer / Director)
// ---------------------------------------------------------------------------

class EditTagsScreen extends StatefulWidget {
  const EditTagsScreen({super.key, required this.serverUrl, required this.userId, required this.token, required this.itemId, required this.itemName});
  final String serverUrl;
  final String userId;
  final String token;
  final String itemId;
  final String itemName;

  @override
  State<EditTagsScreen> createState() => _EditTagsScreenState();
}

class _EditTagsScreenState extends State<EditTagsScreen> {
  final _api = JellyfinApiService();
  Map<String, dynamic>? _fullItem;
  bool _loading = true;
  bool _saving = false;
  List<String> _writers = [];
  List<String> _directors = [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final item = await _api.getItemForEdit(widget.serverUrl, widget.userId, widget.token, widget.itemId);
      final people = (item['People'] as List<dynamic>?)?.whereType<Map<String, dynamic>>() ?? const [];
      _fullItem = item;
      _writers = people.where((p) => p['Type'] == 'Writer').map((p) => _asString(p['Name']) ?? '').where((n) => n.isNotEmpty).toList();
      _directors = people.where((p) => p['Type'] == 'Director').map((p) => _asString(p['Name']) ?? '').where((n) => n.isNotEmpty).toList();
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Could not load: $e')));
    }
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _addName(List<String> list) async {
    final controller = TextEditingController();
    final name = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Add Name'),
        content: TextField(controller: controller, autofocus: true),
        actions: [
          TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Cancel')),
          TextButton(onPressed: () => Navigator.of(context).pop(controller.text.trim()), child: const Text('Add')),
        ],
      ),
    );
    if (name != null && name.isNotEmpty) setState(() => list.add(name));
  }

  Future<void> _save() async {
    final item = _fullItem;
    if (item == null) return;
    setState(() => _saving = true);
    final otherPeople = (item['People'] as List<dynamic>?)?.whereType<Map<String, dynamic>>().where((p) => p['Type'] != 'Writer' && p['Type'] != 'Director').toList() ?? [];
    item['People'] = [
      ...otherPeople,
      for (final name in _writers) {'Name': name, 'Type': 'Writer'},
      for (final name in _directors) {'Name': name, 'Type': 'Director'},
    ];
    try {
      await _api.updateItemMetadata(widget.serverUrl, widget.token, widget.itemId, item);
      if (mounted) Navigator.of(context).pop(true);
    } catch (e) {
      if (mounted) {
        setState(() => _saving = false);
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Could not save: $e')));
      }
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: const Color(0xFF0A0B0D),
    appBar: AppBar(
      backgroundColor: const Color(0xFF0A0B0D),
      leading: IconButton(icon: const Icon(Icons.arrow_back_ios_new), onPressed: () => Navigator.of(context).pop(false)),
      title: Column(children: [Text(widget.itemName, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 16)), const Text('Edit Tags', style: TextStyle(fontSize: 12, color: Color(0xFFA5A7AC)))]),
      centerTitle: true,
      actions: [if (!_loading) TextButton(onPressed: _saving ? null : _save, child: const Text('Save'))],
    ),
    body: _loading
        ? const Center(child: CircularProgressIndicator())
        : ListView(
            padding: const EdgeInsets.all(20),
            children: [
              _PeopleSection(title: 'Writer', names: _writers, onRemove: (i) => setState(() => _writers.removeAt(i)), onAdd: () => _addName(_writers)),
              const SizedBox(height: 24),
              _PeopleSection(title: 'Director', names: _directors, onRemove: (i) => setState(() => _directors.removeAt(i)), onAdd: () => _addName(_directors)),
            ],
          ),
  );
}

class _PeopleSection extends StatelessWidget {
  const _PeopleSection({required this.title, required this.names, required this.onRemove, required this.onAdd});
  final String title;
  final List<String> names;
  final void Function(int index) onRemove;
  final VoidCallback onAdd;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(title, style: const TextStyle(fontWeight: FontWeight.w700, color: Color(0xFFCBCCD0))),
      const SizedBox(height: 10),
      Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          for (var i = 0; i < names.length; i++)
            Chip(
              label: Text(names[i]),
              onDeleted: () => onRemove(i),
              backgroundColor: const Color(0xFF1B1D22),
              labelStyle: const TextStyle(color: Colors.white),
              deleteIconColor: Colors.white70,
            ),
          ActionChip(
            avatar: const Icon(Icons.add, size: 18, color: Colors.white70),
            label: Text('Add ${names.isEmpty ? title : ''}'.trim()),
            onPressed: onAdd,
            backgroundColor: const Color(0xFF1B1D22),
            labelStyle: const TextStyle(color: Colors.white70),
          ),
        ],
      ),
    ],
  );
}

// ---------------------------------------------------------------------------
// Change Artwork
// ---------------------------------------------------------------------------

class ChangeArtworkScreen extends StatefulWidget {
  const ChangeArtworkScreen({super.key, required this.serverUrl, required this.token, required this.itemId, required this.itemName});
  final String serverUrl;
  final String token;
  final String itemId;
  final String itemName;

  @override
  State<ChangeArtworkScreen> createState() => _ChangeArtworkScreenState();
}

class _ChangeArtworkScreenState extends State<ChangeArtworkScreen> {
  final _api = JellyfinApiService();
  List<Map<String, dynamic>>? _posters;
  List<Map<String, dynamic>>? _backdrops;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final results = await Future.wait([
      _api.getRemoteImages(widget.serverUrl, widget.token, widget.itemId, type: 'Primary'),
      _api.getRemoteImages(widget.serverUrl, widget.token, widget.itemId, type: 'Backdrop'),
    ]);
    if (mounted) {
      setState(() {
        _posters = results[0];
        _backdrops = results[1];
      });
    }
  }

  Future<void> _apply(Map<String, dynamic> image, String type) async {
    final url = _asString(image['Url']);
    if (url == null) return;
    setState(() => _busy = true);
    try {
      await _api.downloadRemoteImage(widget.serverUrl, widget.token, widget.itemId, type: type, imageUrl: url, providerName: _asString(image['ProviderName']));
      if (mounted) Navigator.of(context).pop(true);
    } catch (e) {
      if (mounted) {
        setState(() => _busy = false);
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Could not apply that image: $e')));
      }
    }
  }

  Future<void> _addFromUrl(String type) async {
    final urlController = TextEditingController();
    final url = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Add ${type == 'Backdrop' ? 'Background' : 'Poster'} from URL'),
        content: TextField(controller: urlController, decoration: const InputDecoration(hintText: 'https://...'), autofocus: true),
        actions: [
          TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Cancel')),
          TextButton(onPressed: () => Navigator.of(context).pop(urlController.text.trim()), child: const Text('Set')),
        ],
      ),
    );
    if (url == null || url.isEmpty) return;
    setState(() => _busy = true);
    try {
      await _api.setArtworkFromUrl(widget.serverUrl, widget.token, widget.itemId, url, type: type);
      if (mounted) Navigator.of(context).pop(true);
    } catch (e) {
      if (mounted) {
        setState(() => _busy = false);
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Could not set artwork: $e')));
      }
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: const Color(0xFF0A0B0D),
    appBar: AppBar(
      backgroundColor: const Color(0xFF0A0B0D),
      leading: IconButton(icon: const Icon(Icons.arrow_back_ios_new), onPressed: () => Navigator.of(context).pop(false)),
      title: Column(children: [Text(widget.itemName, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 16)), const Text('Change Artwork', style: TextStyle(fontSize: 12, color: Color(0xFFA5A7AC)))]),
      centerTitle: true,
    ),
    body: AbsorbPointer(
      absorbing: _busy,
      child: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          _ArtworkSection(
            title: 'Posters',
            subtitle: 'Posters are used in lists and grids.',
            images: _posters,
            onTapImage: (img) => _apply(img, 'Primary'),
            onAddFromUrl: () => _addFromUrl('Primary'),
          ),
          const SizedBox(height: 28),
          _ArtworkSection(
            title: 'Default Background',
            subtitle: 'Used in TV and Desktop. Defines the background colors for all platforms.',
            images: _backdrops,
            onTapImage: (img) => _apply(img, 'Backdrop'),
            onAddFromUrl: () => _addFromUrl('Backdrop'),
          ),
        ],
      ),
    ),
  );
}

class _ArtworkSection extends StatelessWidget {
  const _ArtworkSection({required this.title, required this.subtitle, required this.images, required this.onTapImage, required this.onAddFromUrl});
  final String title;
  final String subtitle;
  final List<Map<String, dynamic>>? images;
  final void Function(Map<String, dynamic> image) onTapImage;
  final VoidCallback onAddFromUrl;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Row(children: [
        Expanded(child: Text(title, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 16))),
        IconButton(icon: const Icon(Icons.add_photo_alternate_outlined, color: Colors.white70), onPressed: onAddFromUrl),
      ]),
      Text(subtitle, style: const TextStyle(fontSize: 12, color: Color(0xFFA5A7AC))),
      const SizedBox(height: 12),
      if (images == null)
        const Center(child: Padding(padding: EdgeInsets.symmetric(vertical: 20), child: CircularProgressIndicator()))
      else if (images!.isEmpty)
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 12),
          child: Column(children: [
            const Text('No artwork found.', style: TextStyle(color: Color(0xFFA5A7AC))),
            const SizedBox(height: 12),
            OutlinedButton(onPressed: onAddFromUrl, child: Text('Add a $title')),
          ]),
        )
      else
        SizedBox(
          height: 130,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            itemCount: images!.length,
            separatorBuilder: (_, _) => const SizedBox(width: 10),
            itemBuilder: (context, index) {
              final img = images![index];
              final url = _asString(img['Url']);
              final width = _asInt(img['Width']);
              final height = _asInt(img['Height']);
              return GestureDetector(
                onTap: url == null ? null : () => onTapImage(img),
                child: Column(
                  children: [
                    ClipRRect(
                      borderRadius: BorderRadius.circular(6),
                      child: url == null
                          ? Container(width: 160, height: 90, color: const Color(0xFF1B1D22))
                          : SinemaImage(imageUrl: url, width: 160, height: 90, fit: BoxFit.cover),
                    ),
                    if (width != null && height != null) Padding(padding: const EdgeInsets.only(top: 4), child: Text('$width x $height', style: const TextStyle(fontSize: 11, color: Color(0xFFA5A7AC)))),
                  ],
                ),
              );
            },
          ),
        ),
    ],
  );
}

// ---------------------------------------------------------------------------
// File Info
// ---------------------------------------------------------------------------

class FileInfoScreen extends StatefulWidget {
  const FileInfoScreen({super.key, required this.serverUrl, required this.userId, required this.token, required this.itemId, required this.itemName});
  final String serverUrl;
  final String userId;
  final String token;
  final String itemId;
  final String itemName;

  @override
  State<FileInfoScreen> createState() => _FileInfoScreenState();
}

class _FileInfoScreenState extends State<FileInfoScreen> {
  final _api = JellyfinApiService();
  Map<String, dynamic>? _source;
  List<dynamic> _streams = const [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final results = await Future.wait([
        _api.getFileInfo(widget.serverUrl, widget.userId, widget.token, widget.itemId),
        _api.getMediaStreams(widget.serverUrl, widget.userId, widget.token, widget.itemId),
      ]);
      _source = results[0] as Map<String, dynamic>?;
      _streams = results[1] as List<dynamic>;
    } catch (_) {}
    if (mounted) setState(() => _loading = false);
  }

  @override
  Widget build(BuildContext context) {
    final path = _asString(_source?['Path']);
    final container = _asString(_source?['Container'])?.toUpperCase();
    final sizeBytes = _asNum(_source?['Size']);
    final bitrate = _asNum(_source?['Bitrate']);
    final sizeLabel = sizeBytes == null ? null : '${(sizeBytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
    final bitrateLabel = bitrate == null ? null : '${(bitrate / 1000000).toStringAsFixed(1)} Mbps';
    final videoStreams = _streams.whereType<Map<String, dynamic>>().where((s) => s['Type'] == 'Video').toList();
    final audioStreams = _streams.whereType<Map<String, dynamic>>().where((s) => s['Type'] == 'Audio').toList();
    final subtitleStreams = _streams.whereType<Map<String, dynamic>>().where((s) => s['Type'] == 'Subtitle').toList();

    return Scaffold(
      backgroundColor: const Color(0xFF0A0B0D),
      appBar: AppBar(
        backgroundColor: const Color(0xFF0A0B0D),
        leading: IconButton(icon: const Icon(Icons.arrow_back_ios_new), onPressed: () => Navigator.of(context).pop()),
        title: Column(children: [Text(widget.itemName, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 16)), const Text('File Info', style: TextStyle(fontSize: 12, color: Color(0xFFA5A7AC)))]),
        centerTitle: true,
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(20),
              children: [
                if (path != null)
                  Container(
                    padding: const EdgeInsets.all(14),
                    decoration: BoxDecoration(color: const Color(0xFF1B1D22), borderRadius: BorderRadius.circular(10)),
                    child: Row(children: [
                      Expanded(child: Text(path, style: const TextStyle(fontSize: 13))),
                      IconButton(
                        icon: const Icon(Icons.copy, size: 18),
                        onPressed: () {
                          Clipboard.setData(ClipboardData(text: path));
                          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Path copied')));
                        },
                      ),
                    ]),
                  ),
                const SizedBox(height: 16),
                Row(
                  children: [
                    if (container != null) Expanded(child: _InfoLine('Container', container)),
                    if (sizeLabel != null) Expanded(child: _InfoLine('Size', sizeLabel)),
                    if (bitrateLabel != null) Expanded(child: _InfoLine('Bitrate', bitrateLabel)),
                  ],
                ),
                if (videoStreams.isNotEmpty) ...[
                  const SizedBox(height: 20),
                  const Text('Video Streams', style: TextStyle(fontWeight: FontWeight.w700)),
                  const Divider(color: Color(0xFF252529)),
                  for (final s in videoStreams) ListTile(contentPadding: EdgeInsets.zero, title: Text('${_asInt(s['Height']) ?? '?'}p (${(_asString(s['Codec']) ?? '').toUpperCase()})')),
                ],
                if (audioStreams.isNotEmpty) ...[
                  const SizedBox(height: 12),
                  const Text('Audio Streams', style: TextStyle(fontWeight: FontWeight.w700)),
                  const Divider(color: Color(0xFF252529)),
                  for (final s in audioStreams)
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: s['IsDefault'] == true ? const Icon(Icons.check, color: Colors.green, size: 20) : const SizedBox(width: 20),
                      title: Text('${_asString(s['Language']) ?? _asString(s['DisplayTitle']) ?? 'Unknown'} (${(_asString(s['Codec']) ?? '').toUpperCase()}${s['Channels'] != null ? ' ${s['Channels']}ch' : ''})'),
                    ),
                ],
                if (subtitleStreams.isNotEmpty) ...[
                  const SizedBox(height: 12),
                  const Text('Subtitle Streams', style: TextStyle(fontWeight: FontWeight.w700)),
                  const Divider(color: Color(0xFF252529)),
                  for (final s in subtitleStreams)
                    ListTile(contentPadding: EdgeInsets.zero, title: Text('${_asString(s['Language']) ?? _asString(s['DisplayTitle']) ?? 'Unknown'} (${(_asString(s['Codec']) ?? '').toUpperCase()})')),
                ],
                if (path == null && container == null && videoStreams.isEmpty) const Padding(padding: EdgeInsets.symmetric(vertical: 24), child: Text('File info is unavailable for this item.')),
              ],
            ),
    );
  }
}

import 'package:flutter/material.dart';

import 'iptv_models.dart';
import 'iptv_repository.dart';

class IptvSourcesScreen extends StatelessWidget {
  const IptvSourcesScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final repo = IptvRepository.instance;
    return Scaffold(
      appBar: AppBar(
        title: const Text('PLAYLISTS', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700, letterSpacing: 1.8)),
        actions: [
          IconButton(
            tooltip: 'Refresh all',
            onPressed: repo.hasSources ? repo.refreshAll : null,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const IptvSourceEditor())),
        icon: const Icon(Icons.add),
        label: const Text('Add Playlist'),
      ),
      body: AnimatedBuilder(
        animation: repo,
        builder: (context, _) {
          final sources = repo.sources;
          if (sources.isEmpty) {
            return const Center(
              child: Padding(
                padding: EdgeInsets.all(32),
                child: Text(
                  'Add an M3U playlist URL or an Xtream Codes login from your IPTV provider to get started.',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: Color(0xFFA5A7AC), height: 1.4),
                ),
              ),
            );
          }
          return ListView.separated(
            padding: const EdgeInsets.only(bottom: 96),
            itemCount: sources.length,
            separatorBuilder: (_, _) => const Divider(height: 1, color: Color(0xFF1B1D22)),
            itemBuilder: (context, index) {
              final source = sources[index];
              final refreshing = repo.isRefreshing(source.id);
              final error = repo.errorFor(source.id);
              return ListTile(
                contentPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 6),
                leading: Icon(source.type == IptvSourceType.xtream ? Icons.dns_outlined : Icons.playlist_play),
                title: Text(source.name, style: const TextStyle(fontWeight: FontWeight.w600)),
                subtitle: Text(
                  error ?? (refreshing ? 'Updating…' : (source.type == IptvSourceType.xtream ? 'Xtream Codes · ${source.serverBase}' : 'M3U · ${source.url}')),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: error != null ? Colors.redAccent : const Color(0xFFA5A7AC)),
                ),
                trailing: refreshing
                    ? const SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2))
                    : IconButton(icon: const Icon(Icons.refresh), onPressed: () => repo.refresh(source.id)),
                onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => IptvSourceEditor(existing: source))),
              );
            },
          );
        },
      ),
    );
  }
}

class IptvSourceEditor extends StatefulWidget {
  const IptvSourceEditor({super.key, this.existing});
  final IptvSource? existing;

  @override
  State<IptvSourceEditor> createState() => _IptvSourceEditorState();
}

class _IptvSourceEditorState extends State<IptvSourceEditor> {
  late IptvSourceType _type = widget.existing?.type ?? IptvSourceType.m3u;
  late final _name = TextEditingController(text: widget.existing?.name ?? '');
  late final _url = TextEditingController(text: widget.existing?.url ?? '');
  late final _username = TextEditingController(text: widget.existing?.username ?? '');
  late final _password = TextEditingController(text: widget.existing?.password ?? '');
  late final _epg = TextEditingController(text: widget.existing?.epgUrl ?? '');
  late final _userAgent = TextEditingController(text: widget.existing?.userAgent ?? '');
  bool _showPassword = false;
  bool _showAdvanced = false;
  String? _validation;

  @override
  void dispose() {
    for (final c in [_name, _url, _username, _password, _epg, _userAgent]) {
      c.dispose();
    }
    super.dispose();
  }

  String _normalizedUrl(String raw) {
    final v = raw.trim();
    if (v.isEmpty) return v;
    return v.startsWith('http://') || v.startsWith('https://') ? v : 'http://$v';
  }

  Future<void> _save() async {
    final url = _normalizedUrl(_url.text);
    if (url.isEmpty || Uri.tryParse(url)?.host.isEmpty != false) {
      setState(() => _validation = _type == IptvSourceType.xtream ? 'Enter the server address, e.g. http://line.example.com:8080' : 'Enter the playlist URL.');
      return;
    }
    if (_type == IptvSourceType.xtream && (_username.text.trim().isEmpty || _password.text.isEmpty)) {
      setState(() => _validation = 'Xtream Codes needs a username and password.');
      return;
    }
    final epg = _epg.text.trim().isEmpty ? '' : _normalizedUrl(_epg.text);
    final name = _name.text.trim().isNotEmpty ? _name.text.trim() : (Uri.tryParse(url)?.host ?? 'Playlist');
    final repo = IptvRepository.instance;
    final existing = widget.existing;
    final source = existing == null
        ? IptvSource(
            id: DateTime.now().microsecondsSinceEpoch.toRadixString(36),
            name: name,
            type: _type,
            url: url,
            username: _username.text.trim(),
            password: _password.text,
            epgUrl: epg,
            userAgent: _userAgent.text.trim(),
          )
        : existing.copyWith(name: name, type: _type, url: url, username: _username.text.trim(), password: _password.text, epgUrl: epg, userAgent: _userAgent.text.trim());
    Navigator.of(context).pop();
    if (existing == null) {
      await repo.addSource(source);
    } else {
      await repo.updateSource(source);
    }
  }

  Future<void> _delete() async {
    final existing = widget.existing;
    if (existing == null) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Remove Playlist?'),
        content: Text('"${existing.name}" and its channels, guide and favorites will be removed from Sinema.'),
        actions: [
          TextButton(onPressed: () => Navigator.of(context).pop(false), child: const Text('Cancel')),
          TextButton(onPressed: () => Navigator.of(context).pop(true), child: const Text('Remove')),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    Navigator.of(context).pop();
    await IptvRepository.instance.removeSource(existing.id);
  }

  Widget _field(TextEditingController controller, String label, {String? hint, bool obscure = false, Widget? suffix, TextInputType? keyboard}) => Padding(
        padding: const EdgeInsets.only(bottom: 14),
        child: TextField(
          controller: controller,
          obscureText: obscure,
          autocorrect: false,
          enableSuggestions: false,
          keyboardType: keyboard,
          decoration: InputDecoration(labelText: label, hintText: hint, suffixIcon: suffix),
        ),
      );

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(
          title: Text(widget.existing == null ? 'ADD PLAYLIST' : 'EDIT PLAYLIST', style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700, letterSpacing: 1.8)),
          actions: [
            if (widget.existing != null) IconButton(onPressed: _delete, icon: const Icon(Icons.delete_outline), tooltip: 'Remove'),
          ],
        ),
        body: ListView(
          padding: const EdgeInsets.all(20),
          children: [
            SegmentedButton<IptvSourceType>(
              segments: const [
                ButtonSegment(value: IptvSourceType.m3u, label: Text('M3U URL'), icon: Icon(Icons.link)),
                ButtonSegment(value: IptvSourceType.xtream, label: Text('Xtream Codes'), icon: Icon(Icons.dns_outlined)),
              ],
              selected: {_type},
              onSelectionChanged: (s) => setState(() {
                _type = s.first;
                _validation = null;
              }),
            ),
            const SizedBox(height: 24),
            _field(_name, 'Name', hint: 'My provider'),
            if (_type == IptvSourceType.m3u)
              _field(_url, 'Playlist URL', hint: 'http://example.com/get.php?…&type=m3u_plus', keyboard: TextInputType.url)
            else ...[
              _field(_url, 'Server', hint: 'http://line.example.com:8080', keyboard: TextInputType.url),
              _field(_username, 'Username'),
              _field(
                _password,
                'Password',
                obscure: !_showPassword,
                suffix: IconButton(
                  icon: Icon(_showPassword ? Icons.visibility_off : Icons.visibility),
                  onPressed: () => setState(() => _showPassword = !_showPassword),
                ),
              ),
            ],
            _field(
              _epg,
              _type == IptvSourceType.xtream ? 'EPG URL (optional)' : 'EPG / XMLTV URL',
              hint: _type == IptvSourceType.xtream ? 'Uses your provider\'s guide when empty' : 'http://example.com/epg.xml.gz',
              keyboard: TextInputType.url,
            ),
            if (_type == IptvSourceType.m3u)
              const Padding(
                padding: EdgeInsets.only(bottom: 14),
                child: Text('Leave the EPG empty to use the guide named inside the playlist, if it has one.', style: TextStyle(color: Color(0xFFA5A7AC), fontSize: 12)),
              ),
            TextButton.icon(
              onPressed: () => setState(() => _showAdvanced = !_showAdvanced),
              icon: Icon(_showAdvanced ? Icons.expand_less : Icons.expand_more),
              label: const Text('Advanced'),
              style: TextButton.styleFrom(alignment: Alignment.centerLeft, foregroundColor: const Color(0xFFA5A7AC)),
            ),
            if (_showAdvanced) _field(_userAgent, 'User agent (optional)', hint: 'Only if your provider requires one'),
            if (_validation != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: Text(_validation!, style: const TextStyle(color: Colors.redAccent)),
              ),
            const SizedBox(height: 8),
            SizedBox(height: 50, child: FilledButton(onPressed: _save, child: Text(widget.existing == null ? 'Add Playlist' : 'Save'))),
            const SizedBox(height: 16),
            const Text(
              'Your playlist login is stored only on this device. Channels load once, then refresh in the background every day; the guide every 12 hours.',
              style: TextStyle(color: Color(0xFFA5A7AC), fontSize: 12, height: 1.4),
            ),
          ],
        ),
      );
}

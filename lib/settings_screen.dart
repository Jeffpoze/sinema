import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'arr_service.dart';
import 'main.dart';
import 'services/jellyfin_api_service.dart';
import 'settings_controller.dart';

class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key, required this.settings, required this.session});
  final SettingsController settings;
  final JellyfinSession session;

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('SETTINGS', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700, letterSpacing: 1.8))),
        body: ListView(
          children: [
            _SettingsRow(title: 'Account', subtitle: session.username, onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => AccountScreen(session: session, settings: settings)))),
            _SettingsRow(title: 'Appearance', onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => AppearanceScreen(settings: settings)))),
            _SettingsRow(title: 'Playback', onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => PlaybackScreen(settings: settings)))),
            _SettingsRow(title: 'Ratings & Logos', onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => RatingsScreen(settings: settings)))),
            _SettingsRow(title: 'Sonarr & Radarr', onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => ArrSettingsScreen(settings: settings)))),
            _SettingsRow(title: 'About', onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const AboutScreen()))),
          ],
        ),
      );
}

class _SettingsRow extends StatelessWidget {
  const _SettingsRow({required this.title, this.subtitle, required this.onTap});
  final String title;
  final String? subtitle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Column(
        children: [
          ListTile(
            title: Text(title, style: const TextStyle(fontSize: 16)),
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (subtitle != null) Padding(padding: const EdgeInsets.only(right: 8), child: Text(subtitle!, style: const TextStyle(color: Color(0xFFA5A7AC)))),
                const Icon(Icons.chevron_right, color: Color(0xFFA5A7AC)),
              ],
            ),
            onTap: onTap,
          ),
          const Divider(height: 1, color: Color(0xFF1B1D22), indent: 20),
        ],
      );
}

class AccountScreen extends StatelessWidget {
  const AccountScreen({super.key, required this.session, required this.settings});
  final JellyfinSession session;
  final SettingsController settings;

  Future<void> _signOut(BuildContext context) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('serverUrl');
    await prefs.remove('userId');
    await prefs.remove('accessToken');
    if (!context.mounted) return;
    Navigator.of(context).pushAndRemoveUntil(MaterialPageRoute(builder: (_) => AuthenticationScreen(settings: settings)), (route) => false);
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('ACCOUNT', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700, letterSpacing: 1.8))),
        body: ListView(
          children: [
            _InfoRow(label: 'Username', value: session.username),
            _InfoRow(label: 'Server', value: session.serverUrl),
            const SizedBox(height: 24),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: SizedBox(
                width: double.infinity,
                height: 48,
                child: OutlinedButton(
                  style: OutlinedButton.styleFrom(foregroundColor: const Color(0xFFFF8A80), side: const BorderSide(color: Color(0xFFFF8A80))),
                  onPressed: () => _signOut(context),
                  child: const Text('Sign Out'),
                ),
              ),
            ),
          ],
        ),
      );
}

class _InfoRow extends StatelessWidget {
  const _InfoRow({required this.label, required this.value});
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) => Column(
        children: [
          ListTile(
            title: Text(label, style: const TextStyle(fontSize: 16)),
            trailing: Text(value, style: const TextStyle(color: Color(0xFFA5A7AC))),
          ),
          const Divider(height: 1, color: Color(0xFF1B1D22), indent: 20),
        ],
      );
}

class AppearanceScreen extends StatelessWidget {
  const AppearanceScreen({super.key, required this.settings});
  final SettingsController settings;

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('APPEARANCE', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700, letterSpacing: 1.8))),
        body: ListView(
          padding: const EdgeInsets.all(20),
          children: [
            const Text('Theme Color', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
            const SizedBox(height: 4),
            const Text('Choose the accent color used throughout the app.', style: TextStyle(color: Color(0xFFA5A7AC))),
            const SizedBox(height: 20),
            AnimatedBuilder(
              animation: settings,
              builder: (context, _) => Wrap(
                spacing: 16,
                runSpacing: 16,
                children: [
                  for (final option in accentColorOptions)
                    _ColorSwatch(
                      option: option,
                      selected: settings.accentColor.toARGB32() == option.color.toARGB32(),
                      onTap: () => settings.setAccentColor(option.color),
                    ),
                ],
              ),
            ),
          ],
        ),
      );
}

class _ColorSwatch extends StatelessWidget {
  const _ColorSwatch({required this.option, required this.selected, required this.onTap});
  final AccentColorOption option;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => GestureDetector(
        onTap: onTap,
        child: Column(
          children: [
            Container(
              width: 56,
              height: 56,
              decoration: BoxDecoration(
                color: option.color,
                shape: BoxShape.circle,
                border: selected ? Border.all(color: Colors.white, width: 3) : null,
              ),
              child: selected ? const Icon(Icons.check, color: Colors.white) : null,
            ),
            const SizedBox(height: 8),
            Text(option.name, style: const TextStyle(fontSize: 12, color: Color(0xFFA5A7AC))),
          ],
        ),
      );
}

class PlaybackScreen extends StatelessWidget {
  const PlaybackScreen({super.key, required this.settings});
  final SettingsController settings;

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('PLAYBACK', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700, letterSpacing: 1.8))),
        body: AnimatedBuilder(
          animation: settings,
          builder: (context, _) => ListView(
            children: [
              const Padding(
                padding: EdgeInsets.fromLTRB(20, 20, 20, 8),
                child: Text('Skip Interval', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
              ),
              for (final seconds in skipIntervalOptions)
                RadioListTile<int>(
                  value: seconds,
                  groupValue: settings.skipSeconds,
                  title: Text('$seconds seconds'),
                  onChanged: (value) {
                    if (value != null) settings.setSkipSeconds(value);
                  },
                ),
              const Divider(color: Color(0xFF1B1D22)),
              const Padding(
                padding: EdgeInsets.fromLTRB(20, 12, 20, 4),
                child: Text('Default Quality', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
              ),
              const Padding(
                padding: EdgeInsets.fromLTRB(20, 0, 20, 8),
                child: Text('Used when a new video starts playing. Lower this if playback lags on a slow connection.', style: TextStyle(color: Color(0xFFA5A7AC))),
              ),
              for (final quality in defaultQualityOptions)
                RadioListTile<String>(
                  value: quality,
                  groupValue: settings.defaultQuality,
                  title: Text(quality.qualityLabel),
                  onChanged: (value) {
                    if (value != null) settings.setDefaultQuality(value);
                  },
                ),
            ],
          ),
        ),
      );
}

class RatingsScreen extends StatefulWidget {
  const RatingsScreen({super.key, required this.settings});
  final SettingsController settings;

  @override
  State<RatingsScreen> createState() => _RatingsScreenState();
}

class _RatingsScreenState extends State<RatingsScreen> {
  late final _omdbController = TextEditingController(text: widget.settings.omdbApiKey);
  late final _tmdbController = TextEditingController(text: widget.settings.tmdbApiKey);

  @override
  void dispose() {
    _omdbController.dispose();
    _tmdbController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('RATINGS & LOGOS', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700, letterSpacing: 1.8))),
        body: ListView(
          padding: const EdgeInsets.all(20),
          children: [
            const Text('IMDb Ratings', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
            const SizedBox(height: 8),
            const Text(
              'Jellyfin\'s own rating is whatever its metadata provider set — usually TheTVDB for TV shows or TMDB for movies. '
              'To also show a real IMDb rating, get a free API key at omdbapi.com and paste it here.',
              style: TextStyle(color: Color(0xFFA5A7AC)),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _omdbController,
              decoration: const InputDecoration(labelText: 'OMDB API Key', border: OutlineInputBorder()),
              onSubmitted: (value) => widget.settings.setOmdbApiKey(value.trim()),
            ),
            const SizedBox(height: 12),
            FilledButton(
              onPressed: () {
                widget.settings.setOmdbApiKey(_omdbController.text.trim());
                ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Saved')));
              },
              child: const Text('Save'),
            ),
            const SizedBox(height: 32),
            const Text('Network Logos', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
            const SizedBox(height: 8),
            const Text(
              'The Networks screen and home banner show a real Netflix/Apple TV/etc. logo when one is available, fetched live from '
              'themoviedb.org. Get a free API key at themoviedb.org/settings/api and paste it here.',
              style: TextStyle(color: Color(0xFFA5A7AC)),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _tmdbController,
              decoration: const InputDecoration(labelText: 'TMDB API Key', border: OutlineInputBorder()),
              onSubmitted: (value) => widget.settings.setTmdbApiKey(value.trim()),
            ),
            const SizedBox(height: 12),
            FilledButton(
              onPressed: () {
                widget.settings.setTmdbApiKey(_tmdbController.text.trim());
                ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Saved')));
              },
              child: const Text('Save'),
            ),
          ],
        ),
      );
}

class ArrSettingsScreen extends StatefulWidget {
  const ArrSettingsScreen({super.key, required this.settings});
  final SettingsController settings;

  @override
  State<ArrSettingsScreen> createState() => _ArrSettingsScreenState();
}

class _ArrSettingsScreenState extends State<ArrSettingsScreen> {
  late final _sonarrUrlController = TextEditingController(text: widget.settings.sonarrUrl);
  late final _sonarrKeyController = TextEditingController(text: widget.settings.sonarrApiKey);
  late final _radarrUrlController = TextEditingController(text: widget.settings.radarrUrl);
  late final _radarrKeyController = TextEditingController(text: widget.settings.radarrApiKey);
  bool _testingSonarr = false;
  bool _testingRadarr = false;

  @override
  void dispose() {
    _sonarrUrlController.dispose();
    _sonarrKeyController.dispose();
    _radarrUrlController.dispose();
    _radarrKeyController.dispose();
    super.dispose();
  }

  Future<void> _testAndSave({required bool isSonarr}) async {
    final url = (isSonarr ? _sonarrUrlController : _radarrUrlController).text.trim();
    final key = (isSonarr ? _sonarrKeyController : _radarrKeyController).text.trim();
    setState(() => isSonarr ? _testingSonarr = true : _testingRadarr = true);
    String message;
    var succeeded = false;
    try {
      if (url.isEmpty || key.isEmpty) {
        throw Exception('Enter both the server URL and API key.');
      }
      await ArrService.testConnection(url, key);
      succeeded = true;
      message = 'Connected — saved.';
    } catch (e) {
      message = 'Couldn\'t connect: ${e.toString().replaceFirst('Exception: ', '')}';
    }
    if (succeeded) {
      if (isSonarr) {
        await widget.settings.setSonarrUrl(url);
        await widget.settings.setSonarrApiKey(key);
      } else {
        await widget.settings.setRadarrUrl(url);
        await widget.settings.setRadarrApiKey(key);
      }
    }
    if (!mounted) return;
    setState(() => isSonarr ? _testingSonarr = false : _testingRadarr = false);
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _clear({required bool isSonarr}) async {
    if (isSonarr) {
      _sonarrUrlController.clear();
      _sonarrKeyController.clear();
      await widget.settings.setSonarrUrl('');
      await widget.settings.setSonarrApiKey('');
    } else {
      _radarrUrlController.clear();
      _radarrKeyController.clear();
      await widget.settings.setRadarrUrl('');
      await widget.settings.setRadarrApiKey('');
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('SONARR & RADARR', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700, letterSpacing: 1.8))),
        body: ListView(
          padding: const EdgeInsets.all(20),
          children: [
            const Text(
              'Jellyfin only knows about episodes and movies it has already scanned as files. Connecting your own Sonarr and/or '
              'Radarr instance lets the Calendar show the real release schedule, including upcoming items that haven\'t downloaded yet.',
              style: TextStyle(color: Color(0xFFA5A7AC)),
            ),
            const SizedBox(height: 24),
            const Text('Sonarr (TV)', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
            const SizedBox(height: 12),
            TextField(
              controller: _sonarrUrlController,
              keyboardType: TextInputType.url,
              decoration: const InputDecoration(labelText: 'Server URL', hintText: 'http://192.168.1.10:8989', border: OutlineInputBorder()),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _sonarrKeyController,
              obscureText: true,
              decoration: const InputDecoration(labelText: 'API Key', border: OutlineInputBorder()),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                FilledButton(
                  onPressed: _testingSonarr ? null : () => _testAndSave(isSonarr: true),
                  child: _testingSonarr
                      ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                      : const Text('Test & Save'),
                ),
                const SizedBox(width: 12),
                if (widget.settings.sonarrUrl.isNotEmpty)
                  TextButton(onPressed: () => _clear(isSonarr: true), child: const Text('Remove')),
              ],
            ),
            const SizedBox(height: 32),
            const Text('Radarr (Movies)', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
            const SizedBox(height: 12),
            TextField(
              controller: _radarrUrlController,
              keyboardType: TextInputType.url,
              decoration: const InputDecoration(labelText: 'Server URL', hintText: 'http://192.168.1.10:7878', border: OutlineInputBorder()),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _radarrKeyController,
              obscureText: true,
              decoration: const InputDecoration(labelText: 'API Key', border: OutlineInputBorder()),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                FilledButton(
                  onPressed: _testingRadarr ? null : () => _testAndSave(isSonarr: false),
                  child: _testingRadarr
                      ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                      : const Text('Test & Save'),
                ),
                const SizedBox(width: 12),
                if (widget.settings.radarrUrl.isNotEmpty)
                  TextButton(onPressed: () => _clear(isSonarr: false), child: const Text('Remove')),
              ],
            ),
          ],
        ),
      );
}

class AboutScreen extends StatelessWidget {
  const AboutScreen({super.key});

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('ABOUT', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700, letterSpacing: 1.8))),
        body: const Padding(
          padding: EdgeInsets.all(20),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('Sinema', style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700)),
            SizedBox(height: 8),
            Text('Version 1.0.0', style: TextStyle(color: Color(0xFFA5A7AC))),
            SizedBox(height: 16),
            Text('A personal Jellyfin client.', style: TextStyle(color: Color(0xFFA5A7AC))),
          ]),
        ),
      );
}

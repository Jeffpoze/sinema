import 'package:flutter/material.dart';

import 'arr_service.dart';
import 'main.dart';
import 'services/jellyfin_api_service.dart';
import 'servers_screen.dart';
import 'services/server_store.dart';
import 'settings_controller.dart';
import 'watch_history_screen.dart';

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
            _SettingsRow(title: 'Servers', subtitle: '${session.serverType.label}', onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => ServersScreen(settings: settings)))),
            _SettingsRow(title: 'Watch History', onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => WatchHistoryScreen(session: session, settings: settings)))),
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

  // Forgets this server; the app moves to another saved server, Live TV
  // only, or the welcome screen.
  Future<void> _signOut(BuildContext context) async {
    await ServerStore.instance.remove(session.accountId);
    if (!context.mounted) return;
    goHome(context, settings);
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('ACCOUNT', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700, letterSpacing: 1.8))),
        body: ListView(
          children: [
            _InfoRow(label: 'Username', value: session.username),
            _InfoRow(label: 'Server', value: session.serverUrl),
            _InfoRow(label: 'Type', value: session.serverType.label),
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

  bool get _isCustomAccent => !accentColorOptions.any((o) => o.color.toARGB32() == settings.accentColor.toARGB32());

  Future<void> _pickCustomAccent(BuildContext context) async {
    final picked = await showDialog<Color>(
      context: context,
      builder: (_) => _CustomColorDialog(initial: settings.accentColor),
    );
    if (picked != null) settings.setAccentColor(picked);
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('APPEARANCE', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700, letterSpacing: 1.8))),
        body: AnimatedBuilder(
          animation: settings,
          builder: (context, _) => ListView(
            padding: const EdgeInsets.all(20),
            children: [
              const Text('App Theme', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
              const SizedBox(height: 4),
              const Text('The background tint used across every screen.', style: TextStyle(color: Color(0xFFA5A7AC))),
              const SizedBox(height: 16),
              GridView.count(
                crossAxisCount: 2,
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                mainAxisSpacing: 12,
                crossAxisSpacing: 12,
                childAspectRatio: 2.4,
                children: [
                  for (final option in appThemeOptions)
                    _ThemeTile(
                      option: option,
                      accent: settings.accentColor,
                      selected: settings.appTheme.id == option.id,
                      onTap: () => settings.setAppTheme(option),
                    ),
                ],
              ),
              const SizedBox(height: 32),
              const Text('Accent Color', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
              const SizedBox(height: 4),
              const Text('Used for buttons, highlights and progress bars.', style: TextStyle(color: Color(0xFFA5A7AC))),
              const SizedBox(height: 20),
              Wrap(
                spacing: 16,
                runSpacing: 16,
                children: [
                  for (final option in accentColorOptions)
                    _ColorSwatch(
                      option: option,
                      selected: settings.accentColor.toARGB32() == option.color.toARGB32(),
                      onTap: () => settings.setAccentColor(option.color),
                    ),
                  _ColorSwatch(
                    option: AccentColorOption('Custom', _isCustomAccent ? settings.accentColor : const Color(0xFF3A3D44)),
                    selected: _isCustomAccent,
                    icon: Icons.colorize,
                    onTap: () => _pickCustomAccent(context),
                  ),
                ],
              ),
            ],
          ),
        ),
      );
}

class _ThemeTile extends StatelessWidget {
  const _ThemeTile({required this.option, required this.accent, required this.selected, required this.onTap});
  final AppThemeOption option;
  final Color accent;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => GestureDetector(
        onTap: onTap,
        child: Container(
          decoration: BoxDecoration(
            color: option.background,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: selected ? accent : Colors.white12, width: selected ? 2.5 : 1),
          ),
          padding: const EdgeInsets.symmetric(horizontal: 14),
          child: Row(
            children: [
              Container(
                width: 26,
                height: 26,
                decoration: BoxDecoration(color: option.surface, borderRadius: BorderRadius.circular(6), border: Border.all(color: Colors.white10)),
              ),
              const SizedBox(width: 12),
              Expanded(child: Text(option.name, style: const TextStyle(fontWeight: FontWeight.w600))),
              if (selected) Icon(Icons.check_circle, color: accent, size: 20),
            ],
          ),
        ),
      );
}

// A hue ring's worth of control without a dependency: hue + saturation +
// brightness sliders with a live preview.
class _CustomColorDialog extends StatefulWidget {
  const _CustomColorDialog({required this.initial});
  final Color initial;

  @override
  State<_CustomColorDialog> createState() => _CustomColorDialogState();
}

class _CustomColorDialogState extends State<_CustomColorDialog> {
  late HSVColor _color = HSVColor.fromColor(widget.initial);

  Widget _slider(String label, double value, double max, List<Color> track, ValueChanged<double> onChanged) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: const TextStyle(fontSize: 12, color: Color(0xFFA5A7AC))),
          const SizedBox(height: 6),
          Container(
            height: 10,
            decoration: BoxDecoration(borderRadius: BorderRadius.circular(5), gradient: LinearGradient(colors: track)),
          ),
          Slider(value: value, max: max, onChanged: onChanged, activeColor: Colors.white, inactiveColor: Colors.white24),
        ],
      );

  @override
  Widget build(BuildContext context) {
    final preview = _color.toColor();
    return AlertDialog(
      title: const Text('Custom Accent'),
      content: SizedBox(
        width: 320,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              height: 56,
              decoration: BoxDecoration(color: preview, borderRadius: BorderRadius.circular(12)),
              alignment: Alignment.center,
              child: Text(
                '#${preview.toARGB32().toRadixString(16).padLeft(8, '0').substring(2).toUpperCase()}',
                style: const TextStyle(fontWeight: FontWeight.w700, color: Colors.white),
              ),
            ),
            const SizedBox(height: 16),
            _slider('Hue', _color.hue, 360, [
              for (var h = 0; h <= 360; h += 60) HSVColor.fromAHSV(1, h.toDouble(), 1, 1).toColor(),
            ], (v) => setState(() => _color = _color.withHue(v))),
            _slider('Saturation', _color.saturation, 1, [
              _color.withSaturation(0).toColor(),
              _color.withSaturation(1).toColor(),
            ], (v) => setState(() => _color = _color.withSaturation(v))),
            _slider('Brightness', _color.value, 1, [
              Colors.black,
              _color.withValue(1).toColor(),
            ], (v) => setState(() => _color = _color.withValue(v.clamp(0.25, 1.0)))),
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Cancel')),
        FilledButton(onPressed: () => Navigator.of(context).pop(preview), child: const Text('Use Color')),
      ],
    );
  }
}

class _ColorSwatch extends StatelessWidget {
  const _ColorSwatch({required this.option, required this.selected, required this.onTap, this.icon});
  final AccentColorOption option;
  final bool selected;
  final VoidCallback onTap;
  final IconData? icon;

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
              child: selected ? const Icon(Icons.check, color: Colors.white) : (icon == null ? null : Icon(icon, color: Colors.white70)),
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
              const Divider(color: Color(0xFF1B1D22)),
              SwitchListTile(
                value: settings.autoPlayNext,
                onChanged: settings.setAutoPlayNext,
                title: const Text('Auto-Play Next Episode'),
                subtitle: const Text('Counts down during the credits, then starts the next episode.', style: TextStyle(color: Color(0xFFA5A7AC))),
              ),
              SwitchListTile(
                value: settings.autoSkipIntro,
                onChanged: settings.setAutoSkipIntro,
                title: const Text('Skip Intros Automatically'),
                subtitle: const Text('Needs intro markers on your server, e.g. from the Intro Skipper plugin.', style: TextStyle(color: Color(0xFFA5A7AC))),
              ),
              SwitchListTile(
                value: settings.themeMusic,
                onChanged: settings.setThemeMusic,
                title: const Text('Theme Music'),
                subtitle: const Text('Plays a title\'s theme song on its detail page.', style: TextStyle(color: Color(0xFFA5A7AC))),
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

# Sinema

A personal media client for a self-hosted Jellyfin server, for iOS and Android.

## Features

- Home screen with library-organized "recently added" rows, continue watching, and a featured carousel
- Library browsing with sorting by release date, rating, or title
- Movie/show detail pages with a season picker, horizontally scrolling episodes, cast & crew, and a resume-aware play button
- Built-in video player with quality, audio track, and subtitle switching, 15-second skip, playback speed, and screen lock
- Calendar of upcoming releases pulled from your library
- Customizable accent color
- Remember-me sign-in

## Getting Started

### Requirements

- A Jellyfin server reachable from your device
- Xcode, for building and running on iOS
- Android Studio's command-line tools, for building and running on Android

### Download

- **Android**: grab the latest APK from the [Releases page](https://github.com/Jeffpoze/sinema/releases/tag/android-latest) and sideload it (you'll need to allow "install from unknown sources" on your device). A fresh build is published automatically on every push to `main`.
- **iOS**: there's no public download yet — Apple's signing requirements mean it needs to be built and installed from source (see below).

### Running from source

```
flutter pub get
flutter run
```

On first launch, enter your Jellyfin server URL, username, and password.

### Building a release

```
flutter build apk --release   # Android
flutter build ios --release   # iOS, requires a Mac and Xcode
```

## Project layout

- `lib/main.dart` — sign-in, home screen, library browsing
- `lib/detail_screen.dart` — movie/show details, seasons, episodes, cast
- `lib/player_screen.dart` — video playback
- `lib/calendar_screen.dart` — upcoming releases
- `lib/settings_screen.dart`, `lib/settings_controller.dart` — app preferences
- `lib/services/jellyfin_api_service.dart` — Jellyfin API client

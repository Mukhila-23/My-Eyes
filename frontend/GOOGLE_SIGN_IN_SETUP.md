# Google Sign-In setup

The account-creation long press now opens Google's authenticated account
chooser—the same kind of flow used by **Continue with Google**. It no longer
uses Android's old device account-picker API, so it will not take the user to
the **Email or phone / Add account** page shown in the reported issue.

## One-time Google Cloud configuration

1. In [Google Cloud Console](https://console.cloud.google.com/apis/credentials),
   create or select the project for My Eyes.
2. Create an **Android OAuth client** with package name
   `com.example.frontend` and add the SHA-1 certificate fingerprints used for
   debug and release builds.
3. Create a **Web application OAuth client** in the same project. Copy its
   client ID (ending in `.apps.googleusercontent.com`) into the FastAPI
   server's `app/.env` as `GOOGLE_OAUTH_WEB_CLIENT_ID`.
4. Pass the *same* Web client ID to Flutter at build/run time:

```powershell
flutter run --dart-define=GOOGLE_WEB_CLIENT_ID=YOUR_WEB_CLIENT_ID.apps.googleusercontent.com
```

For production, supply the same `--dart-define` to `flutter build apk` or CI.

The Android and Web clients must belong to the same Google Cloud project. An
incorrect package name or SHA-1 can make Google close the chooser after account
selection.

Do **not** put `client_secret` anywhere in Flutter or this project. FastAPI
verifies signed Google ID tokens with Google's public keys; no client secret is
needed or accepted for that verification.

## Current debug build

The currently connected Moto G34 debug build is signed with this SHA-1:

```
56:3B:B8:2B:32:4D:20:E6:BB:E5:A2:CA:FF:D7:F6:A9:72:83:D1:95
```

Add that exact fingerprint to the Android OAuth client for
`com.example.frontend`, save it, then uninstall/rebuild the app or use
`flutter run` again. Google Play Services error `ApiException: 10` means this
registration is missing or does not exactly match the installed APK.

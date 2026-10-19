# Account selection

Press and hold the large button → the device's own list of Google accounts opens
→ touch one → that address becomes the My Eyes account.

This is the flow behind a **"Continue with Google"** button, minus the sign-in.

## What the user sees

The chooser lists **every Google account already on the phone**, and picking a
row returns one email address. Nothing else is asked for.

My Eyes never shows a Google **sign-in form** and never asks for a password.
There is no text field anywhere in this path: a blind user is never asked to type
an address, so a mis-picked account is the only failure mode, and it is undone by
picking again.

If the phone has no Google account yet, the chooser comes back empty and the app
offers an **"add a Google account"** button that opens the system Add account
screen — so the spoken instruction always has a control behind it.

## Why this is not Google Sign-In

`google_sign_in` / Credential Manager was removed from this path. It performs a
real authentication and, when Google cannot match the request to an account it
already trusts, it **replaces the account list with its own "Sign in — Email or
phone" form**. That form is wrong for My Eyes on every count:

- it asks the user to type an address, which a blind user cannot do reliably;
- typing an address that is already on the device produces Google's
  *"This account already exists on your device"* error and a dead end;
- it would also have required an OAuth **web client id** plus a registered
  signing **SHA-1** before the flow worked at all.

`AccountManager.newChooseAccountIntent`, restricted to `com.google`, produces the
same list of the same accounts and **cannot** show a credential form, because it
authenticates nobody — it only reports which account was touched.

| | Account list | Password asked | OAuth setup needed |
|---|---|---|---|
| `AccountManager.newChooseAccountIntent` (`com.google`) | yes | never | no |
| `google_sign_in` / Credential Manager | replaced by a sign-in form | yes | yes (client id + SHA-1) |

## Consequences

Google is a **directory**, never My Eyes' identity provider:

- no Google password, token or session is ever seen, stored or forwarded;
- My Eyes sign-in is the device fingerprint plus the enrollment on the phone, so
  Google being signed out cannot lock anyone out;
- choosing an address that already has a My Eyes account **opens** it instead of
  creating a second one — see `AuthService.useOrCreateAccount`.

## Where the list comes from

`android/app/src/main/kotlin/com/example/frontend/MainActivity.kt`

- `buildChooserIntent()` passes `accountTypes = ["com.google"]`. Passing `null`
  made Android offer *every* account provider installed on the phone, so the
  chooser was filled with WhatsApp, Microsoft 365, Teams, Meet and Snapchat rows
  instead of the Google accounts the user signs in with.
- `readEmailAccounts()` is filtered the same way, so the addresses spoken before
  the chooser opens are exactly the rows it will show.
- `onActivityResult` always clears `pendingAccountResult`, including on BACK, so
  the next long press is always accepted.

## Debugging

Every attempt logs which path ran:

```
[ACCOUNTS] account chosen from the device chooser
[ACCOUNTS] the chooser reported no result within 5 minutes; treating it as dismissed
[ACCOUNTS] unexpected chooser failure: <error>
```

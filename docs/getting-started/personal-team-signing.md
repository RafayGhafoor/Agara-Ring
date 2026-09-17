---
title: Fixing Xcode Personal Team Signing
description: Resolve WeatherKit provisioning-profile and mixed-team signing errors when building PulseLoop from source.
---

# Fixing Xcode Personal Team Signing

This guide documents the fix for the following Xcode signing failure:

```text
Cannot create an iOS App Development provisioning profile for
"com.agara.ring".

Personal development teams do not support the WeatherKit capability.

No profiles for "com.agara.ring" were found.
```

## Root cause

Xcode generates an iOS development provisioning profile from the app target's
bundle identifier, development team, and entitlements. The project requested
the following entitlement:

```xml
<key>com.apple.developer.weatherkit</key>
<true/>
```

WeatherKit is not available to an automatically managed free Personal Team.
Xcode therefore could not create a profile matching the app's requested
capabilities. The "No profiles were found" message was a consequence of that
failure, not a separate missing-file problem.

The project also had different development teams assigned to the app,
extensions, tests, and project-level build settings. An iOS app and its
embedded extensions must be signed consistently. After fixing WeatherKit,
those mixed team values could cause the next signing failure.

## Changes made in the project

### 1. Removed the unsupported WeatherKit entitlement

`PulseLoop/PulseLoop.entitlements` now keeps HealthKit but no longer requests
WeatherKit:

```xml
<dict>
    <key>com.apple.developer.healthkit</key>
    <true/>
</dict>
```

The Swift code can still import and compile against the `WeatherKit`
framework. Entitlements control whether the installed app is authorized to use
the service; they do not control whether the framework can be compiled.

`CoachEnvironmentContextService` already catches WeatherKit request failures.
When WeatherKit is unavailable, coaching continues with city-only context or
without a weather block. The rest of the app remains usable.

### 2. Assigned one development team to every target

The `DEVELOPMENT_TEAM` build setting in
`PulseLoop.xcodeproj/project.pbxproj` was aligned for:

- the `PulseLoop` app;
- `PulseLoopLiveActivityExtension`;
- `PulseLoopWidgetsExtension`;
- `PulseLoopTests`; and
- the Debug and Release project configurations.

The actual team identifier is intentionally not shown here. Each developer
should select their own team in Xcode.

## Xcode setup on another Mac

1. Open `PulseLoop.xcodeproj`.
2. Select the **PulseLoop** project in the Project navigator.
3. Open the **Signing & Capabilities** tab for the `PulseLoop` target.
4. Enable **Automatically manage signing**.
5. Select your Apple ID's **Personal Team**.
6. Repeat the team selection for both extension targets:
   `PulseLoopLiveActivityExtension` and `PulseLoopWidgetsExtension`.
7. Use a unique bundle identifier for the app, for example:
   `com.yourname.pulseloop`.
8. Keep each extension identifier prefixed by the app identifier:

    | Target | Example bundle identifier |
    | --- | --- |
    | PulseLoop | `com.yourname.pulseloop` |
    | Live Activity extension | `com.yourname.pulseloop.LiveActivity` |
    | Widgets extension | `com.yourname.pulseloop.Widgets` |
    | Tests | `com.yourname.pulseloopTests` |

9. Confirm that **WeatherKit** is not listed under the app target's
   capabilities when using a Personal Team.
10. Select an iOS 18 or newer device and run with **Product → Run** (`⌘R`).

Changing the bundle identifiers is necessary when an identifier is already
registered to another Apple Developer account. Bundle identifiers are globally
unique, even for local development.

## What changes with a Personal Team

- Weather-aware coaching is best-effort and may omit live weather data.
- Core coaching, Bluetooth ring synchronization, HealthKit, demo data, and the
  main UI are unaffected by removal of the WeatherKit entitlement.
- Personal Team builds expire after Apple's free-signing period and must be
  rebuilt from Xcode.
- Some Apple capabilities, including WeatherKit and App Groups, require a paid
  Apple Developer Program team. Do not add them back to a Personal Team target.

## Re-enabling WeatherKit with a paid team

Use these steps only when the selected paid Apple Developer Program team
supports WeatherKit:

1. Register the app's bundle identifier in Apple Developer Certificates,
   Identifiers & Profiles.
2. Enable WeatherKit for that App ID.
3. In Xcode, select the paid team for the app and every embedded extension.
4. Add the **WeatherKit** capability to the `PulseLoop` target.
5. Let Xcode regenerate the provisioning profile.

Adding the capability in Xcode restores the
`com.apple.developer.weatherkit` entitlement automatically.

## Troubleshooting

### Xcode still shows the old WeatherKit error

1. Open the app target's **Signing & Capabilities** tab and verify that
   WeatherKit is absent.
2. Use **Product → Clean Build Folder**.
3. Close and reopen Xcode so it reloads the changed entitlements.
4. Click **Try Again** in the signing section.

### An extension cannot be signed

Verify that the app, Live Activity extension, and Widgets extension all use the
same team. Also verify that each extension's bundle identifier starts with the
app's bundle identifier.

### The bundle identifier is unavailable

Replace `com.agara.ring` with an identifier based on a domain or name you
control, then update the two extension identifiers to use the same prefix.

### A physical-device build fails but the simulator builds

Simulator builds do not require a provisioning profile. A successful simulator
build confirms compilation, but device installation still requires a valid
team, unique bundle identifiers, supported entitlements, and a trusted
development certificate.

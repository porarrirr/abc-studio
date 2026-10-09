# Release status

Updated: 2026-10-09 (Asia/Tokyo).

## Completed

- Public OSS repository: https://github.com/porarrirr/abc-studio (MIT recognized by GitHub).
- GitHub Pages: https://porarrirr.github.io/abc-studio/.
  `index.html`, `support.html`, `privacy.html` each returned HTTP 200.
- Three HTML pages authored/refined by GPT-6 Luna / max subagents at the owner's request.
- Responsive Chrome checks: 390×844 viewport, no horizontal overflow;
  real screenshot loaded, support FAQ and privacy navigation worked.
- Contact addresses: musicabc@rarari.org, support@rarari.org, privacy@rarari.org.
  Existing domain catch-all confirmed by owner. No delivery test performed.
- Root MIT license, README, contribution/security documentation and third-party MIT/OFL notices.
- App includes readable MIT/OFL notices, support/privacy/source links and PrivacyInfo.xcprivacy.
- Text credential-pattern audit: 4,906 tracked files and 173 historical text blobs;
  no matches for the checked credential patterns. This is a bounded pattern scan.
- Xcode 27.0 / iOS 27.0 iPhone 17 Pro Simulator: 56 unit tests + 3 UI tests,
  0 failures. Result bundle: local `output/release/validation.xcresult` (ignored).
- App Store Connect record: 6820972807; Bundle ID: jp.porari.abcstudio.
- Version 1.0 build 1 signed/archive/export/upload succeeded. Apple reported
  package processing started; its later processing result has not been checked.
- Japanese promotional text, description, keywords, support/marketing URLs,
  copyright, no-login flag and reviewer notes saved in App Store Connect.
- Two built-in ImageGen screenshots based on actual running app screens;
  final opaque PNGs: iPhone 1206×2622, iPad 2064×2752, saved under `screenshots/ja/`.
- Build 2 archive created to resolve Apple's missing document configuration warning:
  LSSupportsOpeningDocumentsInPlace=NO reflects import-and-edit-local-copy behavior.

## Pending / blocked

- Review has **not** been submitted; App Store release has **not** occurred.
- Browser screenshot upload was denied, then browser access itself was denied.
  The owner explicitly reauthorized access and two-image upload in chat, but the
  browser still reported a saved permission preference blocking appstoreconnect.apple.com.
  No alternate browser/API path was used to bypass the blocked action.
- Owner must clear that saved browser permission block to resume Apple-side work.
- Reviewer contact phone number (with country code) is still required. It is not stored in this public repository.
- Confirm price (free proposed), complete category/subtitle, content-rights and age-rating settings,
  publish the app privacy declaration, upload screenshots, select the processed build and submit review.
- Build 2 distribution export succeeded: local `output/release/build2-export/ABCStudio.ipa` (ignored). Build 2 is not uploaded.

Exact public copy: `metadata-ja.json`. Image prompts/provenance: `screenshots/`.
Build products, logs, signatures and any reviewer private information remain local and ignored.

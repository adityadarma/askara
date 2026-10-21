import WebKit
import AskaraCore

/// Spotify web player (open.spotify.com) helpers:
/// - Ads: when the player is playing an ad, the audio is muted and, if the ad is short, skipped to its end.
///   Ad requests and ad slots are removed separately by `SpotifyAdRules`. The script only acts where the
///   rule list hides `SpotifyAdRules.probeID`, so per-site ad-block exceptions turn it off too.
/// - Shuffle: when "Turn off Spotify shuffle" is on, shuffle is switched off whenever the player turns it on
///   by itself, so songs continue in order. A manual click on the shuffle button (or the S key) is respected
///   until the page reloads.
///
/// Runs in its own content world, so the page can't reach it. The settings live in `window.__askaraSpotify`
/// of that world and are updated with `updateScript` when preferences change.
enum SpotifyEnhancer {
    static func userScript(keepsOrder: Bool) -> WKUserScript {
        WKUserScript(source: source(keepsOrder: keepsOrder), injectionTime: .atDocumentStart,
                     forMainFrameOnly: true, in: .defaultClient)
    }

    /// Run in `.defaultClient` to apply a changed preference to an open Spotify tab.
    static func updateScript(keepsOrder: Bool) -> String {
        "if (window.__askaraSpotify) window.__askaraSpotify.keepOrder = \(keepsOrder);"
    }

    static func isSpotify(_ url: URL?) -> Bool { url?.host?.lowercased() == "open.spotify.com" }

    /// Ads are never longer than this; longer media is a real track and is never skipped.
    static let maxAdSeconds = 90

    static func source(keepsOrder: Bool) -> String {
        #"""
        (() => {
          if (location.hostname !== 'open.spotify.com') return;
          const state = window.__askaraSpotify = { keepOrder: \#(keepsOrder), adBlock: false };

          // Active only where Askara's content rule list applies (respects per-site exceptions).
          const probe = document.createElement('div');
          probe.id = '\#(SpotifyAdRules.probeID)';
          document.documentElement.appendChild(probe);
          state.adBlock = getComputedStyle(probe).display === 'none';
          probe.remove();

          // --- Ads: mute, then skip to the end while the player shows an ad. ---
          const adPattern = /advertisement|iklan/i;
          const isAd = () => {
            if (adPattern.test(document.title)) return true;
            const widget = document.querySelector('[data-testid="now-playing-widget"]');
            if (!widget) return false;
            return adPattern.test(widget.getAttribute('aria-label') || '')
              || !!widget.querySelector('[data-testid="context-item-info-ad"], [data-testid="track-info-advertiser"]');
          };
          const muted = new Set();
          const handleAd = () => {
            for (const media of document.querySelectorAll('audio, video')) {
              if (!media.muted) { media.muted = true; muted.add(media); }
              const d = media.duration;
              if (Number.isFinite(d) && d > 0 && d <= \#(maxAdSeconds) && media.currentTime < d - 0.3) {
                try { media.currentTime = d - 0.1; } catch (_) {}
              }
            }
          };
          const releaseAd = () => {
            for (const media of muted) media.muted = false;
            muted.clear();
          };

          // --- Shuffle: keep songs in order unless the user turned shuffle on. ---
          const shuffleSelector = 'button[data-testid="control-button-shuffle"]';
          let userOverride = false;
          let attempts = 0;
          let lastClick = 0;
          document.addEventListener('click', (event) => {
            if (event.isTrusted && event.target.closest && event.target.closest(shuffleSelector)) userOverride = true;
          }, true);
          document.addEventListener('keydown', (event) => {
            const t = event.target;
            const typing = t && (t.isContentEditable || /^(INPUT|TEXTAREA|SELECT)$/.test(t.tagName));
            if (event.isTrusted && !typing && !event.metaKey && !event.ctrlKey && !event.altKey
                && event.key && event.key.toLowerCase() === 's') userOverride = true;
          }, true);
          const handleShuffle = () => {
            if (!state.keepOrder || userOverride || attempts >= 10) return;
            const button = document.querySelector(shuffleSelector);
            if (!button || button.disabled || button.getAttribute('aria-checked') !== 'true') return;
            const now = Date.now();
            if (now - lastClick < 3000) return;
            lastClick = now;
            attempts += 1;
            button.click();
          };

          setInterval(() => {
            const ad = isAd();
            if (state.adBlock) { if (ad) handleAd(); else if (muted.size) releaseAd(); }
            if (!ad) handleShuffle();
          }, 500);
        })();
        """#
    }
}

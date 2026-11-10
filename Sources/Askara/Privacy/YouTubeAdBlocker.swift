import Foundation
import AskaraCore

/// Removes YouTube video ads before the player sees them, so videos start without ads or a skip button.
///
/// YouTube describes the ads to play inside the player response (`adPlacements`, `adSlots`,
/// `playerAds`). This script deletes those fields wherever the response enters the page:
/// - `ytInitialPlayerResponse`, set by an inline script on the first page load;
/// - `JSON.parse` and `Response.json()`, used for later videos (YouTube is a single-page app).
///
/// Ad elements on the page (banners, feed ads) are hidden separately by `YouTubeAdRules`.
///
/// Fallback: if an ad still plays (for example after a YouTube change), it is muted and skipped.
///
/// It only runs when the rule list hides `YouTubeAdRules.probeID`, so turning the ad blocker off for
/// youtube.com (Privacy Dashboard) disables it too. Injected at document start, before YouTube's scripts.
enum YouTubeAdBlocker {
    static let marker = "__askaraYouTubeRuleRevision"

    static func source(rules: YouTubeAdRuleSet) -> String {
        let config: [String: Any] = [
            "adElementSelectors": rules.adElementSelectors,
            "wrapperSelectors": rules.wrapperSelectors,
            "adKeys": rules.adKeys,
            "wrapperKeys": rules.wrapperKeys,
            "skipSelectors": rules.skipSelectors,
        ]
        let data = try! JSONSerialization.data(withJSONObject: config, options: [.sortedKeys])
        let json = String(decoding: data, as: UTF8.self)
        return """
    (() => {
      const __askaraYouTubeRuleRevision = \(rules.revision);
      const host = location.hostname;
      if (host !== 'youtube.com' && !host.endsWith('.youtube.com')) return;
      const config = \(json);

      // Active only where Askara's content rule list applies (respects per-site exceptions).
      const probe = document.createElement('div');
      probe.id = '\(YouTubeAdRules.probeID)';
      document.documentElement.appendChild(probe);
      const enabled = getComputedStyle(probe).display === 'none';
      probe.remove();
      if (!enabled) return;

      // Feed ads leave an empty grid cell: the content rules hide the ad inside it, not its wrapper.
      // `:has()` isn't allowed in content rule lists, so the wrappers are hidden by a page style instead.
      const adInside = config.adElementSelectors;
      // Only wrappers that hold a single item. A list wrapper (ytd-item-section-renderer) would hide real videos too.
      const wrappers = config.wrapperSelectors;
      const style = document.createElement('style');
      style.textContent = wrappers
        .map((wrapper) => adInside.map((ad) => `${wrapper}:has(${ad})`).join(', '))
        .join(', ') + ' { display: none !important; }';
      document.documentElement.appendChild(style);

      // Fields that tell the player which ads to play. Removing them leaves the video itself intact.
      const adKeys = config.adKeys;
      const prune = (value) => {
        if (!value || typeof value !== 'object') return value;
        // Player responses are sometimes wrapped by endpoint-specific `response`, `data`, or
        // `playerResponse` objects. Visit only those known wrappers, not every parsed object.
        const pending = [value];
        const seen = new WeakSet();
        while (pending.length) {
          const target = pending.pop();
          if (!target || typeof target !== 'object' || seen.has(target)) continue;
          seen.add(target);
          for (const key of adKeys) if (key in target) delete target[key];
          for (const key of config.wrapperKeys) {
            const nested = target[key];
            if (nested && typeof nested === 'object') pending.push(nested);
          }
        }
        return value;
      };

      // First page load: `var ytInitialPlayerResponse = {...}` assigns through this setter.
      let initial;
      try {
        Object.defineProperty(window, 'ytInitialPlayerResponse', {
          configurable: true,
          get: () => initial,
          set: (value) => { initial = prune(value); },
        });
      } catch (_) {}

      // Later videos: player responses arrive through fetch and are parsed as JSON.
      const parse = JSON.parse;
      JSON.parse = function (...args) { return prune(parse.apply(this, args)); };
      const json = Response.prototype.json;
      Response.prototype.json = function (...args) { return json.apply(this, args).then(prune); };

      // Fallback for ads that still get through: mute, then skip as soon as possible.
      const skipSelector = config.skipSelectors.join(', ');
      let player = null;
      let timer = null;
      let mutedByUs = false;
      const video = () => player && player.querySelector('video');
      const stop = () => {
        if (timer) { clearInterval(timer); timer = null; }
        const v = video();
        if (mutedByUs && v) v.muted = false;
        mutedByUs = false;
      };
      const tick = () => {
        if (!player || !player.classList.contains('ad-showing')) return stop();
        const v = video();
        if (v && !v.muted) { v.muted = true; mutedByUs = true; }
        const skip = player.querySelector(skipSelector);
        if (skip && skip.offsetParent !== null) skip.click();
      };
      const update = () => {
        if (!player.classList.contains('ad-showing')) return stop();
        if (!timer) { tick(); timer = setInterval(tick, 300); }
      };
      const attach = (element) => {
        player = element;
        // Watch only the player's class attribute, not the whole page.
        new MutationObserver(update).observe(player, { attributes: true, attributeFilter: ['class'] });
        update();
      };
      const find = () => document.querySelector('.html5-video-player');
      const finder = new MutationObserver(() => {
        const found = find();
        if (found) { finder.disconnect(); attach(found); }
      });
      finder.observe(document.documentElement, { childList: true, subtree: true });
    })();
    """
    }
}

/* KemoFi LiteV2 portal icon sets. Only fixed, built-in SVG fragments are used. */
(function (root) {
  'use strict';

  var sets = {
    classic: {
      coin: '<circle cx="12" cy="12" r="9" fill="none" stroke="currentColor" stroke-width="1.8"/><path d="M12 7v10M9.5 9.5h4a2 2 0 0 1 0 4h-3a2 2 0 0 0 0 4H14" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round"/>',
      pause: '<rect x="6" y="5" width="4" height="14" rx="1"/><rect x="14" y="5" width="4" height="14" rx="1"/>',
      resume: '<path d="M8 5.5v13a1 1 0 0 0 1.52.86l9.5-6.5a1 1 0 0 0 0-1.72l-9.5-6.5A1 1 0 0 0 8 5.5Z"/>',
      free: '<path d="M12 2v4m0 12v4M4.93 4.93l2.83 2.83m8.48 8.48 2.83 2.83M2 12h4m12 0h4M4.93 19.07l2.83-2.83m8.48-8.48 2.83-2.83" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round"/>',
      voucher: '<rect x="2" y="6" width="20" height="12" rx="2" fill="none" stroke="currentColor" stroke-width="2"/><path d="M2 10h20M8 14h4" fill="none" stroke="currentColor" stroke-width="2"/>',
      rates: '<path d="M1 9l2 2c4.97-4.97 13.03-4.97 18 0l-2.1-2.1C15.14 5.14 8.87 5.14 1 9zm4 4 2 2c2.76-2.76 7.24-2.76 10 0l2-2c-3.87-3.87-10.14-3.87-14 0z" fill="none" stroke="currentColor" stroke-width="2"/><circle cx="12" cy="18" r="2" fill="currentColor"/>'
    },
    outline: {
      coin: '<circle cx="12" cy="12" r="8" fill="none" stroke="currentColor" stroke-width="1.6"/><circle cx="12" cy="12" r="3.2" fill="none" stroke="currentColor" stroke-width="1.6"/><path d="M12 4v2m0 12v2M4 12h2m12 0h2" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round"/>',
      pause: '<path d="M9 5v14M15 5v14" fill="none" stroke="currentColor" stroke-width="2.2" stroke-linecap="round"/>',
      resume: '<path d="M8 5.5v13l10-6.5-10-6.5Z" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linejoin="round"/>',
      free: '<circle cx="12" cy="12" r="3.2" fill="none" stroke="currentColor" stroke-width="1.7"/><path d="M12 2.5v3M12 18.5v3M2.5 12h3M18.5 12h3M5.3 5.3l2.1 2.1m9.2 9.2 2.1 2.1m0-13.4-2.1 2.1M7.4 16.6l-2.1 2.1" fill="none" stroke="currentColor" stroke-width="1.7" stroke-linecap="round"/>',
      voucher: '<rect x="2.5" y="6.5" width="19" height="11" rx="2" fill="none" stroke="currentColor" stroke-width="1.7"/><path d="M2.5 10.5h19M8 14h3" fill="none" stroke="currentColor" stroke-width="1.7" stroke-linecap="round"/>',
      rates: '<path d="M3 9.5a13 13 0 0 1 18 0M6.5 13a8.5 8.5 0 0 1 11 0M10 16.5a4 4 0 0 1 4 0" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round"/><circle cx="12" cy="20" r="1" fill="currentColor"/>'
    },
    solid: {
      coin: '<circle cx="12" cy="12" r="9" fill="currentColor"/><path d="M12 7v10M9.5 9.5h4a2 2 0 0 1 0 4h-3a2 2 0 0 0 0 4H14" fill="none" stroke="var(--kemofi-icon-ink, #fff)" stroke-width="1.8" stroke-linecap="round"/>',
      pause: '<rect x="5" y="4" width="5" height="16" rx="1.5" fill="currentColor"/><rect x="14" y="4" width="5" height="16" rx="1.5" fill="currentColor"/>',
      resume: '<path d="M7 4.8v14.4a1.4 1.4 0 0 0 2.18 1.16l10.2-7.2a1.4 1.4 0 0 0 0-2.32l-10.2-7.2A1.4 1.4 0 0 0 7 4.8Z" fill="currentColor"/>',
      free: '<circle cx="12" cy="12" r="3.5" fill="currentColor"/><path d="M12 1.8v4M12 18.2v4M1.8 12h4M18.2 12h4M4.8 4.8l2.8 2.8m8.8 8.8 2.8 2.8m0-14.4-2.8 2.8M7.6 16.4l-2.8 2.8" fill="none" stroke="currentColor" stroke-width="2.2" stroke-linecap="round"/>',
      voucher: '<path d="M2 7.5A2.5 2.5 0 0 1 4.5 5h15A2.5 2.5 0 0 1 22 7.5v2a2.5 2.5 0 0 0 0 5v2a2.5 2.5 0 0 1-2.5 2.5h-15A2.5 2.5 0 0 1 2 16.5v-2a2.5 2.5 0 0 0 0-5v-2Z" fill="currentColor"/><path d="M8 10h8M8 14h5" fill="none" stroke="var(--kemofi-icon-ink, #fff)" stroke-width="1.7" stroke-linecap="round"/>',
      rates: '<path d="M1 9.5a15.5 15.5 0 0 1 22 0l-2.1 2.1a12.5 12.5 0 0 0-17.8 0L1 9.5Zm4 4a10 10 0 0 1 14 0l-2.1 2.1a7 7 0 0 0-9.8 0L5 13.5Zm4 4a4.5 4.5 0 0 1 6 0L12 22l-3-4.5Z" fill="currentColor"/>'
    },
    minimal: {
      coin: '<path d="M7 5h10v14H7z" fill="none" stroke="currentColor" stroke-width="1.8"/><path d="M10 9h3.2a1.6 1.6 0 0 1 0 3.2h-2.4a1.6 1.6 0 0 0 0 3.2H14M12 7v2m0 7.4V18" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round"/>',
      pause: '<path d="M8 6v12M16 6v12" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round"/>',
      resume: '<path d="m9 6 8 6-8 6V6Z" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linejoin="round"/>',
      free: '<path d="M12 4v16M4 12h16M6.3 6.3l11.4 11.4M17.7 6.3 6.3 17.7" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round"/>',
      voucher: '<path d="M3 7h18v10H3z" fill="none" stroke="currentColor" stroke-width="1.8"/><path d="M3 11h18M8 14h4" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round"/>',
      rates: '<path d="M3 10a13 13 0 0 1 18 0M7 14a7 7 0 0 1 10 0M11 18a2 2 0 0 1 2 0" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round"/>'
    },
    rounded: {
      coin: '<rect x="4" y="4" width="16" height="16" rx="6" fill="none" stroke="currentColor" stroke-width="1.8"/><path d="M12 7v10M9.5 9.5h4a2 2 0 0 1 0 4h-3a2 2 0 0 0 0 4H14" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round"/>',
      pause: '<rect x="6" y="5" width="4" height="14" rx="2" fill="currentColor"/><rect x="14" y="5" width="4" height="14" rx="2" fill="currentColor"/>',
      resume: '<path d="M8 5.5v13a1 1 0 0 0 1.6.8l9-6.5a1 1 0 0 0 0-1.6l-9-6.5a1 1 0 0 0-1.6.8Z" fill="currentColor"/>',
      free: '<circle cx="12" cy="12" r="3" fill="none" stroke="currentColor" stroke-width="1.8"/><path d="M12 2.5v3M12 18.5v3M2.5 12h3M18.5 12h3M5.3 5.3l2.1 2.1m9.2 9.2 2.1 2.1m0-13.4-2.1 2.1M7.4 16.6l-2.1 2.1" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round"/>',
      voucher: '<rect x="2" y="6" width="20" height="12" rx="5" fill="none" stroke="currentColor" stroke-width="1.8"/><path d="M2 12h20M8 9v6M16 9v6" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round"/>',
      rates: '<path d="M2 9.5a14 14 0 0 1 20 0M5.5 13.5a9 9 0 0 1 13 0M9.5 17a4 4 0 0 1 5 0" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round"/><circle cx="12" cy="20" r="1.3" fill="currentColor"/>'
    },
    duotone: {
      coin: '<circle cx="12" cy="12" r="9" fill="currentColor" opacity=".22"/><circle cx="12" cy="12" r="7" fill="none" stroke="currentColor" stroke-width="1.8"/><path d="M12 7v10M9.5 9.5h4a2 2 0 0 1 0 4h-3a2 2 0 0 0 0 4H14" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round"/>',
      pause: '<rect x="5" y="4" width="5" height="16" rx="2" fill="currentColor" opacity=".3"/><rect x="14" y="4" width="5" height="16" rx="2" fill="currentColor"/>',
      resume: '<path d="M7 5v14l12-7L7 5Z" fill="currentColor" opacity=".28"/><path d="M9 7.5v9l7.7-4.5L9 7.5Z" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linejoin="round"/>',
      free: '<circle cx="12" cy="12" r="3.5" fill="currentColor" opacity=".3"/><circle cx="12" cy="12" r="1.5" fill="currentColor"/><path d="M12 2v4M12 18v4M2 12h4M18 12h4M4.9 4.9l2.8 2.8m8.6 8.6 2.8 2.8m0-14.2-2.8 2.8M7.7 16.3l-2.8 2.8" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round"/>',
      voucher: '<rect x="2" y="6" width="20" height="12" rx="2" fill="currentColor" opacity=".24"/><path d="M2 10h20M8 14h4" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round"/>',
      rates: '<path d="M1 9a15 15 0 0 1 22 0M5 13a10 10 0 0 1 14 0M9 17a5 5 0 0 1 6 0" fill="none" stroke="currentColor" stroke-width="3" opacity=".25" stroke-linecap="round"/><path d="M1 9a15 15 0 0 1 22 0M5 13a10 10 0 0 1 14 0M9 17a5 5 0 0 1 6 0" fill="none" stroke="currentColor" stroke-width="1.2" stroke-linecap="round"/><circle cx="12" cy="20" r="1.5" fill="currentColor"/>'
    },
    neon: {
      coin: '<circle cx="12" cy="12" r="9" fill="none" stroke="currentColor" stroke-width="1.2" opacity=".45"/><circle cx="12" cy="12" r="7" fill="none" stroke="currentColor" stroke-width="2"/><path d="M12 7v10M9.5 9.5h4a2 2 0 0 1 0 4h-3a2 2 0 0 0 0 4H14" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round"/>',
      pause: '<path d="M8 5v14M16 5v14" fill="none" stroke="currentColor" stroke-width="4" opacity=".3" stroke-linecap="round"/><path d="M8 5v14M16 5v14" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round"/>',
      resume: '<path d="M8 5.5v13l10-6.5-10-6.5Z" fill="none" stroke="currentColor" stroke-width="3.8" opacity=".3" stroke-linejoin="round"/><path d="M8 5.5v13l10-6.5-10-6.5Z" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linejoin="round"/>',
      free: '<circle cx="12" cy="12" r="3" fill="none" stroke="currentColor" stroke-width="3.5" opacity=".3"/><circle cx="12" cy="12" r="2" fill="currentColor"/><path d="M12 2v4M12 18v4M2 12h4M18 12h4M4.9 4.9l2.8 2.8m8.6 8.6 2.8 2.8m0-14.2-2.8 2.8M7.7 16.3l-2.8 2.8" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round"/>',
      voucher: '<rect x="2" y="6" width="20" height="12" rx="2" fill="none" stroke="currentColor" stroke-width="3.6" opacity=".3"/><rect x="2" y="6" width="20" height="12" rx="2" fill="none" stroke="currentColor" stroke-width="1.7"/><path d="M2 10h20M8 14h4" fill="none" stroke="currentColor" stroke-width="1.5"/>',
      rates: '<path d="M2 9.5a14 14 0 0 1 20 0M5.5 13.5a9 9 0 0 1 13 0M9.5 17a4 4 0 0 1 5 0" fill="none" stroke="currentColor" stroke-width="4" opacity=".3" stroke-linecap="round"/><path d="M2 9.5a14 14 0 0 1 20 0M5.5 13.5a9 9 0 0 1 13 0M9.5 17a4 4 0 0 1 5 0" fill="none" stroke="currentColor" stroke-width="1.7" stroke-linecap="round"/><circle cx="12" cy="20" r="1.3" fill="currentColor"/>'
    },
    pixel: {
      coin: '<path d="M7 3h10v2h2v14h-2v2H7v-2H5V5h2V3Zm2 5v8h6V8H9Zm2 2h2v4h-2v-4Z" fill="currentColor" fill-rule="evenodd"/>',
      pause: '<path d="M5 4h6v16H5V4Zm8 0h6v16h-6V4Z" fill="currentColor"/>',
      resume: '<path d="M6 4h4v2h4v2h4v2h2v4h-2v2h-4v2h-4v2H6V4Z" fill="currentColor"/>',
      free: '<path d="M10 2h4v4h4v4h4v4h-4v4h-4v4h-4v-4H6v-4H2v-4h4V6h4V2Zm2 8v4h4v-4h-4Z" fill="currentColor" fill-rule="evenodd"/>',
      voucher: '<path d="M2 5h20v4h-2v6h2v4H2v-4h2V9H2V5Zm5 4v6h10V9H7Zm3 2h4v2h-4v-2Z" fill="currentColor" fill-rule="evenodd"/>',
      rates: '<path d="M2 8h4v2h4v2h4v2h4v2h4v4h-4v-2h-4v-2h-4v-2H6v-2H2V8Z" fill="currentColor"/>'
    }
  };
  var names = {classic: true, outline: true, solid: true, minimal: true, rounded: true, duotone: true, neon: true, pixel: true};

  function apply(name, documentRoot) {
    var selected = names[name] ? name : 'classic';
    var set = sets[selected];
    var rootNode = documentRoot || document;
    rootNode.querySelectorAll('[data-portal-icon]').forEach(function (node) {
      var icon = set[node.getAttribute('data-portal-icon')];
      if (icon) node.innerHTML = icon;
    });
    return selected;
  }

  root.KemoFiPortalIcons = {sets: sets, apply: apply, defaultSet: 'classic'};
})(window);

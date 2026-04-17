// Copyright (c) 2026 Brad Duhon. All Rights Reserved.
// Confidential and Proprietary.
// Unauthorized copying of this file is strictly prohibited.

/** @type {import('tailwindcss').Config} */
export default {
  // content is defined per-app — each app extends this config with its own paths
  content: [],
  theme: {
    extend: {
      colors: {
        amber: {
          primary: '#D97706',
          dark:    '#92400E',
          light:   '#FEF3C7',
        },
        site: {
          bg:      '#FAFAF9',
          text:    '#44403C',
          heading: '#1C1917',
          muted:   '#5C5754', // 6.5:1 contrast on #FAFAF9 — passes WCAG AA
        },
      },
      fontFamily: {
        sans: [
          'ui-sans-serif',
          'system-ui',
          '-apple-system',
          'BlinkMacSystemFont',
          '"Segoe UI"',
          'Roboto',
          '"Helvetica Neue"',
          'Arial',
          'sans-serif',
        ],
        mono: [
          'ui-monospace',
          'SFMono-Regular',
          'Menlo',
          'Monaco',
          'Consolas',
          '"Liberation Mono"',
          '"Courier New"',
          'monospace',
        ],
      },
    },
  },
  plugins: [],
};

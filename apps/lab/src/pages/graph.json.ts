// Copyright (c) 2026 Brad Duhon. All Rights Reserved.
// Confidential and Proprietary.
// Unauthorized copying of this file is strictly prohibited.

import { getCollection } from 'astro:content';
import type { APIContext } from 'astro';

// Count occurrences of tag words in article text for relevance scoring.
// Handles simple plurals and -ing forms so "cloud" matches "clouds", etc.
function countRelevance(tag: string, text: string): number {
  const clean = text.toLowerCase().replace(/[^a-z0-9\s]/g, ' ');
  const words = clean.split(/\s+/).filter(Boolean);
  const parts = tag.toLowerCase().replace(/[^a-z0-9\s]/g, ' ').split(/\s+/).filter(Boolean);

  let count = 0;
  parts.forEach((part) => {
    words.forEach((word) => {
      if (word === part || word === part + 's' || word.startsWith(part + 'ing')) {
        count++;
      }
    });
  });
  return count;
}

export async function GET(_ctx: APIContext) {
  const entries = await getCollection('entries', ({ data }) => !data.draft);
  const sorted = entries.sort((a, b) => b.data.date.valueOf() - a.data.date.valueOf());

  // Article nodes
  const articleNodes = sorted.map((entry) => ({
    id: `article-${entry.slug}`,
    type: 'article' as const,
    label: entry.data.title,
    date: entry.data.date.toISOString().split('T')[0],
    description: entry.data.description,
    tags: entry.data.tags,
    slug: entry.slug,
  }));

  // Tag nodes — deduplicated
  const allTags = [...new Set(sorted.flatMap((e) => e.data.tags))].sort();
  const tagNodes = allTags.map((tag) => ({
    id: `tag-${tag}`,
    type: 'tag' as const,
    label: tag,
  }));

  // Tag edges with per-article relevance scores
  const tagEdges = sorted.flatMap((entry) => {
    const fullText = entry.data.title + ' ' + entry.data.description + ' ' + (entry.body ?? '');
    const rawCounts = entry.data.tags.map((tag) => ({
      tag,
      count: countRelevance(tag, fullText),
    }));
    const maxCount = Math.max(...rawCounts.map((t) => t.count), 1);

    return rawCounts.map(({ tag, count }) => ({
      source: `article-${entry.slug}`,
      target: `tag-${tag}`,
      kind: 'tag' as const,
      relevance: count / maxCount, // normalized 0-1
    }));
  });

  // Semantic edges — articles sharing 2+ tags
  const semanticEdges = [];
  for (let i = 0; i < sorted.length; i++) {
    for (let j = i + 1; j < sorted.length; j++) {
      const shared = sorted[i].data.tags.filter((t) => sorted[j].data.tags.includes(t));
      if (shared.length >= 2) {
        semanticEdges.push({
          source: `article-${sorted[i].slug}`,
          target: `article-${sorted[j].slug}`,
          kind: 'related' as const,
          weight: shared.length,
        });
      }
    }
  }

  return new Response(
    JSON.stringify({
      nodes: [...articleNodes, ...tagNodes],
      edges: [...tagEdges, ...semanticEdges],
      initialCenter: articleNodes[0]?.id ?? null,
    }),
    { headers: { 'Content-Type': 'application/json' } }
  );
}

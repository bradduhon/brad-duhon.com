// Copyright (c) 2026 Brad Duhon. All Rights Reserved.
// Confidential and Proprietary.
// Unauthorized copying of this file is strictly prohibited.

import type { GraphNode, ArticleNode } from './types';

const CARD_W = 280;
const GAP    = 18;

interface Props {
  node: GraphNode;
  allNodes: GraphNode[];
  // Node position in SVG coordinate space (maps 1:1 to CSS px within container)
  nodeX: number;
  nodeY: number;
  // Container dimensions for edge detection
  canvasW: number;
  canvasH: number;
  onClose: () => void;
}

function cardStyle(nodeX: number, nodeY: number, canvasW: number, canvasH: number, estHeight: number) {
  // Shrink card on narrow viewports so it always fits within the canvas.
  const cardW = Math.min(CARD_W, canvasW - 2 * GAP);

  // Flip left if card would overflow the right edge, then clamp to canvas bounds.
  const rawLeft = nodeX + GAP + cardW > canvasW ? nodeX - cardW - GAP : nodeX + GAP;
  const left = Math.max(GAP, Math.min(rawLeft, canvasW - cardW - GAP));

  // Clamp vertically so card stays within canvas
  const top = Math.max(GAP, Math.min(nodeY - estHeight / 2, canvasH - estHeight - GAP));

  return {
    position: 'absolute' as const,
    top: `${top}px`,
    left: `${left}px`,
    width: `${cardW}px`,
    background: '#FAFAF9',
    border: '1.5px solid #D97706',
    borderRadius: '8px',
    padding: '16px',
    boxShadow: '0 4px 24px rgba(0,0,0,0.10)',
    zIndex: 10,
    pointerEvents: 'auto' as const,
  };
}

const closeBtn = {
  position: 'absolute' as const,
  top: '10px',
  right: '12px',
  background: 'none',
  border: 'none',
  cursor: 'pointer',
  fontSize: '14px',
  color: '#78716C',
  lineHeight: 1,
  padding: '2px',
};

export default function PreviewCard({ node, allNodes, nodeX, nodeY, canvasW, canvasH, onClose }: Props) {
  if (node.type === 'article') {
    const article = node as ArticleNode;
    return (
      <div style={cardStyle(nodeX, nodeY, canvasW, canvasH, 220)}>
        <button onClick={onClose} style={closeBtn} aria-label="Close preview">x</button>

        <p style={{ fontSize: '10px', fontFamily: 'monospace', color: '#92400E', marginBottom: '6px' }}>
          {article.date}
        </p>
        <h3 style={{ fontSize: '13px', fontWeight: '600', color: '#1C1917', lineHeight: '1.4', marginBottom: '8px', paddingRight: '20px' }}>
          {article.label}
        </h3>
        <p style={{ fontSize: '12px', color: '#44403C', lineHeight: '1.5', marginBottom: '10px' }}>
          {article.description}
        </p>
        <div style={{ display: 'flex', flexWrap: 'wrap', gap: '4px', marginBottom: '12px' }}>
          {article.tags.map((tag) => (
            <span key={tag} style={{ fontSize: '10px', fontFamily: 'monospace', background: '#FEF3C7', color: '#92400E', padding: '2px 6px', borderRadius: '3px' }}>
              {tag}
            </span>
          ))}
        </div>
        <a href={`/${article.slug}`} style={{ fontSize: '12px', color: '#92400E', fontWeight: '600', textDecoration: 'none' }}>
          Read article →
        </a>
      </div>
    );
  }

  // Tag node
  const tagLabel = node.label;
  const taggedArticles = allNodes
    .filter((n): n is ArticleNode => n.type === 'article' && n.tags.includes(tagLabel))
    .sort((a, b) => b.date.localeCompare(a.date))
    .slice(0, 3);

  const estHeight = 60 + taggedArticles.length * 44;

  return (
    <div style={cardStyle(nodeX, nodeY, canvasW, canvasH, estHeight)}>
      <button onClick={onClose} style={closeBtn} aria-label="Close preview">x</button>

      <p style={{ fontSize: '10px', fontFamily: 'monospace', color: '#92400E', marginBottom: '10px', fontWeight: '700' }}>
        #{tagLabel}
      </p>
      {taggedArticles.length === 0 ? (
        <p style={{ fontSize: '12px', color: '#78716C' }}>No articles yet.</p>
      ) : (
        <ul style={{ display: 'flex', flexDirection: 'column', gap: '10px' }}>
          {taggedArticles.map((article) => (
            <li key={article.id}>
              <a href={`/${article.slug}`} style={{ fontSize: '12px', color: '#1C1917', fontWeight: '600', textDecoration: 'none', lineHeight: '1.4', display: 'block' }}>
                {article.label}
              </a>
              <span style={{ fontSize: '10px', fontFamily: 'monospace', color: '#92400E' }}>{article.date}</span>
            </li>
          ))}
        </ul>
      )}
    </div>
  );
}

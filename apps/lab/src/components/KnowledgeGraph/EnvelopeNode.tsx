// Copyright (c) 2026 Brad Duhon. All Rights Reserved.
// Confidential and Proprietary.
// Unauthorized copying of this file is strictly prohibited.

import type { ArticleNode } from './types';

interface Props {
  node: ArticleNode;
  isCenter: boolean;
  x: number;
  y: number;
  onMouseEnter: () => void;
  onMouseLeave: () => void;
  onClick: (e?: Event) => void;
}

const CENTER_W  = 180;
const CENTER_H  = 80;
const RADIUS    = 18;   // neighbor circle radius

export default function EnvelopeNode({ node, isCenter, x, y, onMouseEnter, onMouseLeave, onClick }: Props) {
  if (isCenter) {
    const w = CENTER_W;
    const h = CENTER_H;
    return (
      <g
        transform={`translate(${x - w / 2}, ${y - h / 2})`}
        style={{ cursor: 'default' }}
        onMouseEnter={onMouseEnter}
        onMouseLeave={onMouseLeave}
        onClick={onClick}
      >
        <rect
          width={w}
          height={h}
          rx="8"
          fill="#FEF9EE"
          stroke="#D97706"
          stroke-width="1.5"
        />
        <foreignObject x="12" y="10" width={w - 24} height={h - 20}>
          <div
            xmlns="http://www.w3.org/1999/xhtml"
            style={{
              fontSize: '11px',
              fontWeight: '600',
              color: '#1C1917',
              lineHeight: '1.4',
              overflow: 'hidden',
              display: '-webkit-box',
              WebkitLineClamp: 3,
              WebkitBoxOrient: 'vertical',
              marginBottom: '4px',
            }}
          >
            {node.label}
          </div>
          <div
            xmlns="http://www.w3.org/1999/xhtml"
            style={{
              fontSize: '9px',
              fontFamily: 'ui-monospace, monospace',
              color: '#92400E',
            }}
          >
            {node.date}
          </div>
        </foreignObject>
      </g>
    );
  }

  // Neighbor — small circle with thin amber ring
  return (
    <g
      transform={`translate(${x}, ${y})`}
      style={{ cursor: 'pointer' }}
      onMouseEnter={onMouseEnter}
      onMouseLeave={onMouseLeave}
      onClick={onClick}
    >
      <circle r={RADIUS} fill="#FAFAF9" stroke="#D97706" stroke-width="1" />
      {/* Small dot center to indicate it's an article */}
      <circle r="3" fill="#D97706" opacity="0.5" />
    </g>
  );
}

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

const CENTER_W    = 180;
const CENTER_H    = 80;
const NEIGHBOR_W  = 120;
const NEIGHBOR_H  = 38;

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

  // Neighbor — small labeled box
  return (
    <g
      transform={`translate(${x - NEIGHBOR_W / 2}, ${y - NEIGHBOR_H / 2})`}
      style={{ cursor: 'pointer' }}
      onMouseEnter={onMouseEnter}
      onMouseLeave={onMouseLeave}
      onClick={onClick}
    >
      <rect
        width={NEIGHBOR_W}
        height={NEIGHBOR_H}
        rx="5"
        fill="#FAFAF9"
        stroke="#D97706"
        stroke-width="0.75"
      />
      <foreignObject x="6" y="5" width={NEIGHBOR_W - 12} height={NEIGHBOR_H - 10}>
        <div
          xmlns="http://www.w3.org/1999/xhtml"
          style={{
            fontSize: '8px',
            fontWeight: '500',
            color: '#44403C',
            lineHeight: '1.3',
            overflow: 'hidden',
            display: '-webkit-box',
            WebkitLineClamp: 2,
            WebkitBoxOrient: 'vertical',
          }}
        >
          {node.label}
        </div>
      </foreignObject>
    </g>
  );
}

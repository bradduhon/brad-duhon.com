// Copyright (c) 2026 Brad Duhon. All Rights Reserved.
// Confidential and Proprietary.
// Unauthorized copying of this file is strictly prohibited.

import type { TagNode as TagNodeType } from './types';

interface Props {
  node: TagNodeType;
  isCenter: boolean;
  relevance?: number; // 0-1 — scales node size relative to article content
  x: number;
  y: number;
  onMouseEnter: () => void;
  onMouseLeave: () => void;
  onClick: (e?: Event) => void;
}

const BASE_FONT  = 10;
const BASE_PAD_X = 10;
const BASE_H     = 22;
const CHAR_W     = 6.5;

export default function TagNode({ node, isCenter, relevance = 0, x, y, onMouseEnter, onMouseLeave, onClick }: Props) {
  // Scale font and container by relevance: 1x (low) to 1.65x (high)
  const scale = 1 + relevance * 0.65;
  const fontSize = Math.round(BASE_FONT * scale);
  const padX    = Math.round(BASE_PAD_X * scale);
  const h       = Math.round(BASE_H * scale);
  const w       = Math.max(node.label.length * (fontSize * CHAR_W / BASE_FONT) + padX * 2, 36);
  const rx      = h / 2;

  const fill        = isCenter ? '#FEF3C7' : 'transparent';
  const stroke      = isCenter ? '#D97706' : '#D6D3D1';
  const strokeWidth = isCenter ? 1.5 : 1;
  const textFill    = isCenter ? '#92400E' : '#78716C';

  return (
    <g
      transform={`translate(${x - w / 2}, ${y - h / 2})`}
      style={{ cursor: isCenter ? 'default' : 'pointer' }}
      onMouseEnter={onMouseEnter}
      onMouseLeave={onMouseLeave}
      onClick={onClick}
    >
      <rect
        width={w}
        height={h}
        rx={rx}
        fill={fill}
        stroke={stroke}
        stroke-width={strokeWidth}
      />
      <text
        x={w / 2}
        y={h / 2 + 1}
        text-anchor="middle"
        dominant-baseline="middle"
        font-family="ui-monospace, monospace"
        font-size={fontSize}
        font-weight={isCenter ? '600' : '400'}
        fill={textFill}
      >
        {node.label}
      </text>
    </g>
  );
}

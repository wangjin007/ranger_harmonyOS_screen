import { display } from '@kit.ArkUI';

const MAX_SIDE = 1280;

function even(n: number): number {
  return n & ~1;
}

export function scaledCaptureSize(): [number, number, number, number] {
  try {
    const d = display.getDefaultDisplaySync();
    let w = d.width;
    let h = d.height;
    const ori = d.orientation as number;
    const rot = d.rotation as number;
    const rotationDeg = ((rot % 4) + 4) % 4 * 90;
    const landscape = ori === 1 || ori === 3 || rot === 1 || rot === 3;
    if (landscape && w < h) {
      const tmp = w;
      w = h;
      h = tmp;
    } else if (!landscape && h < w) {
      const tmp = w;
      w = h;
      h = tmp;
    }
    const longest = Math.max(w, h);
    if (longest > MAX_SIDE) {
      const scale = MAX_SIDE / longest;
      w = Math.floor(w * scale);
      h = Math.floor(h * scale);
    }
    return [even(w), even(h), d.id, rotationDeg];
  } catch (err) {
    return [720, 1280, 0, 0];
  }
}

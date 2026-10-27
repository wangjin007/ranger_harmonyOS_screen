export const startServer: (port: number, width: number, height: number, fps: number, bitrate: number,
  displayId: number, rotationDeg: number) => number;
export const startClient: (hosts: string, port: number, width: number, height: number, fps: number, bitrate: number,
  displayId: number, rotationDeg: number, pin: number) => number;
export const updateSize: (width: number, height: number, displayId: number, rotationDeg: number) => number;
export const stopServer: () => number;
export const getState: () => number;
export const sendVolume: (percent: number) => boolean;

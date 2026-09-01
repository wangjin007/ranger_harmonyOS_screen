export const startServer: (port: number, width: number, height: number, fps: number, bitrate: number,
  displayId: number) => number;
export const stopServer: () => number;
export const getState: () => number;

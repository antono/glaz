// Message codes shared with ../frame_app.lua. See ../docs/PROTOCOL.md.

// Host -> Frame
const menuSet = 0x20;
const menuHide = 0x21;
const menuShow = 0x22;
const clockSet = 0x23;
const notify = 0x24;
const netResponse = 0x25;
const statusGet = 0x26;
const settingsSet = 0x27;
const location = 0x28;
const filesGet = 0x29;
const fileGet = 0x2A;
const input = 0x2B;
const photoTake = 0x2C;
const recSet = 0x2D;

// Frame -> Host
const menuSelect = 0x11;
const menuCursor = 0x12;
const menuOpen = 0x13;
const menuClose = 0x14;
const appStart = 0x15;
const appStop = 0x16;
const menuLevel = 0x17;
const appBackground = 0x18;
const netRequest = 0x19;
const photoFrom = 0x1A;
const status = 0x1B;
const locationGet = 0x1C;
const files = 0x1D;
const fileData = 0x1E;
const recStart = 0x1F;

// The frame_msg camera library's own codes, used by Camera and Time series
const photoChunk = 0x07;
const photoEnd = 0x08;

// The frame_msg audio library's own codes, used by Recorder
const audioChunk = 0x05;
const audioEnd = 0x06;

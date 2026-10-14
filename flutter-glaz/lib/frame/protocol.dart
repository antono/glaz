// Message codes shared with ../frame_app.lua. See ../docs/PROTOCOL.md.

// Host -> Frame
const menuSet = 0x20;
const menuHide = 0x21;
const menuShow = 0x22;
const clockSet = 0x23;
const notify = 0x24;
const netResponse = 0x25;

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

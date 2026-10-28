// Message codes shared with ../glaz/glaz.lua. See ../docs/PROTOCOL.md.

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
const moduleCall = 0x2D;
const handsOff = 0x2E;

// HANDS_OFF's payload: who holds the glasses' own gestures off
const handsOffNone = 0;
const handsOffRemote = 1; // the Remote tab
const handsOffKeyboard = 2; // a keyboard remote
const appOpen = 0x2F;
const luaEval = 0x30;

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
const recDrop = 0x10;
const luaResult = 0x09;
const textGet = 0x0A;

/// apps/gemini/gemini.lua: [op, page, n (2), top (2)] -- op 1 opens link n,
/// op 2 asks for lines from n
const geminiGet = 0x0D;

/// apps/notifications/notifications.lua: [op, n (4)] -- op 1 the list from number n,
/// op 2 notification n, all of it
const noticesGet = 0x0E;

/// apps/translate/translate.lua: [op, sess, from (2), count] -- op 0 close,
/// 1 lines from `from` (stops following), 2 the last `count` (follows);
/// 3, 4 reserved (phone microphone, photo)
const translate = 0x0F;

/// apps/scales/scales.lua: [n] scale n wanted, answered with MODULE_CALL
/// 'scales' (services/scales.dart)
const scaleGet = 0x02;

/// apps/tuner/tuner.lua: [1, mic] a tuning on screen, listen (mic 0 the
/// phone's, 1 the glasses'), [0] stop
const tuner = 0x03;

/// apps/assistant/assistant.lua: [op, id (2)] -- op 1 the chats, 2 go on with
/// chat id, 3 a new chat
const assist = 0x04;

/// apps/flipper/flipper.lua: [1] show the Flipper, [0] stop, [2, seq] frame taken
const flipper = 0x0B;

/// The terminal: [1, cols, rows] start, [0] stop, [2, seq] frame taken
/// (apps/term/term.lua).
const term = 0x0C;

// The frame_msg camera library's own codes, used by Camera and Time series
const photoChunk = 0x07;
const photoEnd = 0x08;

// The frame_msg audio library's own codes, used by Recorder
const audioChunk = 0x05;
const audioEnd = 0x06;

// REC_START's fourth byte: the sound is a question for the assistant
const forAssistant = 1;

// REC_START's fourth byte: the sound is for Translate
const forTranslate = 2;

// REC_START's fourth byte: the sound is for the Tuner
const forTuner = 3;

// PHOTO_FROM's byte: the photo is Translate's to read, not to keep
const photoForTranslate = 255;

/// The codes by name, for the log (services/glaz_log.dart).
const codeNames = {
  menuSet: 'MENU_SET',
  menuHide: 'MENU_HIDE',
  menuShow: 'MENU_SHOW',
  clockSet: 'CLOCK_SET',
  notify: 'NOTIFY',
  netResponse: 'NET_RESPONSE',
  statusGet: 'STATUS_GET',
  settingsSet: 'SETTINGS_SET',
  location: 'LOCATION',
  filesGet: 'FILES_GET',
  fileGet: 'FILE_GET',
  input: 'INPUT',
  photoTake: 'PHOTO_TAKE',
  moduleCall: 'MODULE_CALL',
  handsOff: 'HANDS_OFF',
  appOpen: 'APP_OPEN',
  luaEval: 'LUA_EVAL',
  menuSelect: 'MENU_SELECT',
  menuCursor: 'MENU_CURSOR',
  menuOpen: 'MENU_OPEN',
  menuClose: 'MENU_CLOSE',
  appStart: 'APP_START',
  appStop: 'APP_STOP',
  menuLevel: 'MENU_LEVEL',
  appBackground: 'APP_BACKGROUND',
  netRequest: 'NET_REQUEST',
  photoFrom: 'PHOTO_FROM',
  status: 'STATUS',
  locationGet: 'LOCATION_GET',
  files: 'FILES',
  fileData: 'FILE_DATA',
  recStart: 'REC_START',
  recDrop: 'REC_DROP',
  luaResult: 'LUA_RESULT',
  flipper: 'FLIPPER',
  term: 'TERM',
  textGet: 'TEXT_GET',
  geminiGet: 'GEM_GET',
  noticesGet: 'NOTICES_GET',
  translate: 'TRANSLATE',
  tuner: 'TUNER',
  scaleGet: 'SCALE_GET',
  photoChunk: 'photo chunk',
  photoEnd: 'photo end',
  audioChunk: 'audio chunk',
  audioEnd: 'audio end',
};

-- A photo for the phone's remote (PHOTO_TAKE): part of frame_app.lua, in a
-- file of its own, loaded for a photo and dropped after. ASCII only, see
-- docs/PROTOCOL.md, "Remote".
--
-- idle: nothing else uses the camera, so it goes off again after.
-- A photo for the phone's remote, the way modules/photo.lua takes one: the
-- camera library loaded just for it (modules load only while in use, and so
-- does this), auto exposure given time to settle, and PHOTO_FROM 0 first so
-- the phone files it with the single shots. The loop waits meanwhile, about
-- 1.5 s of exposure plus the transfer.
local QUALITIES = { 'VERY_LOW', 'LOW', 'MEDIUM', 'HIGH', 'VERY_HIGH' }
local PHOTO_WARMUP = 1.5

return function(size, quality, idle, release_hardware)
  if not frame.bluetooth.is_connected() then return end
  local ok, camera = pcall(require, 'camera.min')
  if not ok or type(camera) ~= 'table' then return end
  if size % 2 == 1 or size < 100 or size > 720 then size = 512 end
  pcall(frame.camera.power_save, false)
  local settled = frame.time.utc() + PHOTO_WARMUP
  while frame.time.utc() < settled do
    pcall(camera.run_auto_exposure)
    frame.sleep(0.1)
  end
  for _ = 1, 50 do
    if pcall(frame.bluetooth.send, string.char(0x1A, 0)) then break end
    frame.sleep(0.01)
  end
  pcall(camera.capture_and_send, { resolution = size, pan = 0, raw = false,
                                   quality = QUALITIES[quality] or 'MEDIUM' })
  -- a running Camera or a series in the background may still want it
  if idle then release_hardware() end
end

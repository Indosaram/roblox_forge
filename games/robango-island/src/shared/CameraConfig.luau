--!strict
-- Robango play camera (QuarterView options), Durango framing (refs R05/R08/R09): a high 3/4 view
-- about 50 studs out, where the survivor reads at ~16% of an 800x360 phone's height. The A1 share
-- config put the arm at ~93 studs (a ~20 px figure, p134 v54). Pinch or the wheel zooms between
-- 12 and 60 studs. Closer in, the pitch eases from 55 down to 30 degrees and the focus rises to the
-- head, so the closest zoom is an over-the-shoulder view. Yaw stays fixed on touch.
-- The client adds the per-island yaw and the UI test for the raw-touch pinch.
return table.freeze({
	pitch = 55,
	closePitch = 30,
	fieldOfView = 30,
	distance = 50,
	minDistance = 12,
	maxDistance = 60,
	closeFocusHeight = 3.5,
	touchRotate = false,
})

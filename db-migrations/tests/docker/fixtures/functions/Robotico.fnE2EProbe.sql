-- ============================================================================
-- Robotico.fnE2EProbe — E2E fixture: anytime function (grate hash-redeploy)
-- ============================================================================
-- FIXTURE, NOT part of either migration chain (see the sibling up/ probe). Copied
-- into eazybusiness/functions/ only for the Docker E2E (Section B), then removed.
-- It proves grate's anytime semantics: an anytime object re-runs (CREATE OR ALTER)
-- whenever its file hash changes, and NOT otherwise.
--
-- VERSION 1 (multiplier = 2). Section B edits this to VERSION 2 (multiplier = 3)
-- to trigger a single hash-change redeploy of exactly this object.
CREATE OR ALTER FUNCTION Robotico.fnE2EProbe (@n int)
RETURNS int
AS
BEGIN
    RETURN @n * 2;
END
GO

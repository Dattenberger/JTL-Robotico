-- ============================================================================
-- Robotico.spEnsureArticleCustomField — internal helper (auto-create binding)
-- ============================================================================
-- Ensures an article-attribute binding exists for a custom field, creating the
-- tArtikelAttribut + tArtikelAttributSprache entries if missing. Handles the
-- concurrent-creation race (UNIQUE violation 2627 -> re-query). Internal helper;
-- public writes go through Robotico.spSetArticleCustomFieldValue.
--
-- Returns 0 on success. A missing custom-field definition is a deployment/config
-- error: the proc RAISERRORs (severity 16) which the outer CATCH re-raises via
-- THROW, so the caller gets a thrown error, never a -1 return code.
--
-- STRUCTURE (QG3 B6): the binding row and its language row are ensured in two
-- SELF-HEALING steps instead of one atomic two-INSERT block. The binding lookup
-- deliberately does NOT join tArtikelAttributSprache: a binding whose language row
-- is missing for @kSprache (rows only for another language, or a crash between the
-- two INSERTs of an earlier version) must be FOUND here — re-INSERTing it would hit
-- the UNIQUE constraint (2627) on every future call, permanently wedging the field
-- for that article. Step 3 then creates the missing language row on its own. Because
-- each step repairs whatever the previous state left behind, no runtime transaction
-- is needed — and none is used on purpose: JTL workflows may call this inside their
-- own transaction, where a ROLLBACK in a nested CATCH would kill the caller's
-- transaction too. (grate --transaction only wraps the DEPLOY of this file, it has
-- no effect on runtime calls.)
--
-- Ported from WorkflowProcedures/api/CustomFieldAPI.sql (2026-07-10).
-- ============================================================================

CREATE OR ALTER PROCEDURE Robotico.spEnsureArticleCustomField
    @kArtikel INT,
    @fieldName NVARCHAR(255),
    @kSprache INT = 0,  -- Default: German
    @kArtikelAttribut INT OUTPUT,
    @currentValue NVARCHAR(MAX) OUTPUT
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @kAttribut INT;

    BEGIN TRY
        -- Step 1: Lookup kAttribut for the custom field definition
        SELECT @kAttribut = attr.kAttribut
        FROM dbo.tAttribut attr
        INNER JOIN dbo.tAttributSprache attrs
            ON attr.kAttribut = attrs.kAttribut
        WHERE attrs.cName = @fieldName
          AND attrs.kSprache = @kSprache
          AND attr.nIstFreifeld = 1;  -- Only custom fields

        IF @kAttribut IS NULL
        BEGIN
            -- Severity 16 inside a TRY transfers control to the outer CATCH (which
            -- THROWs), so execution never returns here — no RETURN follows.
            RAISERROR('Custom field definition not found in JTL: %s', 16, 1, @fieldName);
        END

        -- Step 2: Ensure the binding row (WITHOUT the language join — see header).
        SELECT @kArtikelAttribut = aa.kArtikelAttribut
        FROM dbo.tArtikelAttribut aa
        WHERE aa.kArtikel = @kArtikel
          AND aa.kAttribut = @kAttribut
          AND aa.kShop = 0;   -- kShop = 0 (Global)

        IF @kArtikelAttribut IS NULL
        BEGIN
            BEGIN TRY
                INSERT INTO dbo.tArtikelAttribut (kArtikel, kAttribut, kShop)
                VALUES (@kArtikel, @kAttribut, 0);

                SET @kArtikelAttribut = SCOPE_IDENTITY();
            END TRY
            BEGIN CATCH
                -- Race: another workflow created the binding concurrently.
                -- UNIQUE constraint on (kArtikel, kAttribut, kShop) -> error 2627.
                IF ERROR_NUMBER() = 2627
                BEGIN
                    SELECT @kArtikelAttribut = aa.kArtikelAttribut
                    FROM dbo.tArtikelAttribut aa
                    WHERE aa.kArtikel = @kArtikel
                      AND aa.kAttribut = @kAttribut
                      AND aa.kShop = 0;

                    IF @kArtikelAttribut IS NULL
                        THROW;  -- Still NULL = different error occurred
                END
                ELSE
                    THROW;  -- Not a constraint violation, re-throw
            END CATCH
        END

        -- Step 3: Ensure the language row for @kSprache (self-healing: also repairs a
        -- binding that lost its language row to a crash, or that only carries rows for
        -- other languages).
        IF NOT EXISTS (SELECT 1 FROM dbo.tArtikelAttributSprache
                       WHERE kArtikelAttribut = @kArtikelAttribut AND kSprache = @kSprache)
        BEGIN
            BEGIN TRY
                INSERT INTO dbo.tArtikelAttributSprache (
                    kArtikelAttribut,
                    kSprache,
                    cWertVarchar
                )
                VALUES (
                    @kArtikelAttribut,
                    @kSprache,
                    NULL  -- Empty initially, populated by caller
                );
            END TRY
            BEGIN CATCH
                -- 2627/2601: a concurrent caller inserted the language row between the
                -- existence check and here — the row exists now, which is all we need.
                IF ERROR_NUMBER() NOT IN (2627, 2601)
                    THROW;
            END CATCH
        END

        -- Step 4: Read the current value for the (now guaranteed) language row.
        SELECT @currentValue = aas.cWertVarchar
        FROM dbo.tArtikelAttributSprache aas
        WHERE aas.kArtikelAttribut = @kArtikelAttribut
          AND aas.kSprache = @kSprache;

        RETURN 0;  -- Success

    END TRY
    BEGIN CATCH
        THROW;  -- Propagate error to caller
    END CATCH
END
GO

-- ============================================================================
-- Teardown: Artikel Versandklasse nach Gewicht - entfernt ALLE Feature-Objekte
-- ============================================================================
--
-- Author:  Sanda Gilca
-- Date:    2026-07-01
--
-- Entfernt die Aktion und die Entscheidungsfunktion. Run gegen eazybusiness.
-- Idempotent (IF OBJECT_ID-Guards) und transaktional.
--
-- Hinweis: Das Droppen von CustomWorkflows.spArtikelVersandklasseNachGewicht
-- entfernt auch dessen DisplayName (= die JTL-Aktionsregistrierung); es gibt
-- keine separate Registry-Tabelle. Eine evtl. in dbo.tWorkflowAktion
-- verdrahtete Referenz (deine Workflow-Konfiguration) wird NICHT angefasst.
-- Bereits gesetzte Versandklassen an Artikeln bleiben unveraendert.
-- ============================================================================

USE [eazybusiness]
GO

SET XACT_ABORT ON
GO

BEGIN TRANSACTION
GO

IF OBJECT_ID('CustomWorkflows.spArtikelVersandklasseNachGewicht', 'P') IS NOT NULL
    DROP PROCEDURE CustomWorkflows.spArtikelVersandklasseNachGewicht;
IF OBJECT_ID('Robotico.fnVersandklasseNachGewicht', 'FN') IS NOT NULL
    DROP FUNCTION Robotico.fnVersandklasseNachGewicht;

COMMIT TRANSACTION;
PRINT '+ Teardown complete - Versandklasse-nach-Gewicht-Objekte entfernt';
GO


JTL_DirectTableQuery("
DECLARE @kPickliste INT = " + ToString$(PickListPositionWarehouse.PickListInternalId) + "
DECLARE @kArtikel INT = " + ToString$(PickListPositionWarehouse.PickListInternalId) + "
DECLARE @kWarenlagerPlatz INT = " + ToString$(PickListPositionWarehouse.PickListInternalId) + "

DECLARE @kPickliste INT = 77448;
DECLARE @kArtikel INT = 1195;
DECLARE @kWarenlagerPlatz INT = 568;

SELECT CONCAT(FORMAT(tPP.fAnzahl, '0.######'), ' Stück in ', lAV.cAuftragsnummer,' - KNr. ', lAV.kKunde, IIF(IsNull(lAV.cRechnungsadresseFirma, '') = '', '', CONCAT(' - ' ,lAV.cRechnungsadresseFirma)), ' - ',lAV.cRechnungsadresseNachname, ', ',lAV.cRechnungsadresseVorname)
FROM [eazybusiness].[dbo].[tPicklistePos] tPP
LEFT JOIN [eazybusiness].[Verkauf].[tAuftragPosition] tAP ON tAP.kAuftragPosition = tPP.kBestellPos
LEFT JOIN [eazybusiness].[Verkauf].[lvAuftragsverwaltung] lAV ON lAV.kAuftrag = tAP.kAuftrag
LEFT JOIN [eazybusiness].[dbo].[tArtikel] tArt ON tArt.kArtikel = tPP.kArtikel
WHERE tPP.kPickliste = @kPickliste
	AND tPP.kArtikel = @kArtikel
	AND kWarenlagerPlatz = @kWarenlagerPlatz
	AND kWarengruppe = 2

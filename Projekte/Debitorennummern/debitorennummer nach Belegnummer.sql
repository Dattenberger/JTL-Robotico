use eazybusiness;

WITH AuftragsDaten AS
(SELECT tA.cAuftragsNr, tA.kAuftrag, tK.nDebitorennr AS Debitor, lvK.cUSTID as USTID_Kunde, tA.cKundeUstId as USTID_Auftrag, IIF(lvK.cUSTID != tA.cKundeUstId, 'Nicht gleich', 'Gleich') as 'UST_Vergleich'
    FROM Verkauf.lvAuftragsverwaltung lA
    LEFT JOIN dbo.tkunde tK ON lA.kKunde = tK.kKunde
    LEFT JOIN Kunde.lvKunde lvK ON lA.kKunde = lvK.kKunde
    LEFT JOIN Verkauf.tAuftrag tA ON lA.kAuftrag = tA.kAuftrag)
SELECT AD.cAuftragsNr as Belegnummer, AD.Debitor, AD.USTID_Kunde, AD.USTID_Auftrag, AD.UST_Vergleich
FROM AuftragsDaten AD
UNION ALL
SELECT tRE.cRechnungsnr as Belegnummer, AD.Debitor, AD.USTID_Kunde, AD.USTID_Auftrag, AD.UST_Vergleich
FROM AuftragsDaten AD
    LEFT JOIN Verkauf.tAuftragRechnung tAR ON tAR.kAuftrag = AD.kAuftrag
    INNER JOIN Rechnung.tRechnung tRE ON tRE.kRechnung = tAR.kRechnung
UNION ALL
SELECT tG.cGutschriftNr as Belegnummer, AD.Debitor, AD.USTID_Kunde, AD.USTID_Auftrag, AD.UST_Vergleich
FROM AuftragsDaten AD
    LEFT JOIN Verkauf.tAuftragRechnung tAR ON tAR.kAuftrag = AD.kAuftrag
    LEFT JOIN Rechnung.tRechnung tRE ON tRE.kRechnung = tAR.kRechnung
    INNER JOIN dbo.tgutschrift tG ON tG.kRechnung = tRE.kRechnung
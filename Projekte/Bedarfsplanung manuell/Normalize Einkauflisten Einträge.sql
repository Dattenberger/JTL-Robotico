UPDATE [eazybusiness].[dbo].[tArtikelEinkaufsliste]
  SET kWarenlager = 17
  WHERE kWarenlager = 0

DECLARE @kAttributUnhandlich INT = 251; --Werte sind hier in tArtikelAttributSprache.nWertInt gespeichert. 1 steht für ja, ist undhandlich.
DECLARE @kAttributAktion INT = 272; --Werte sind hier in tArtikelAttributSprache.cWertVarchar gespeichert.

WITH Attribute AS (
    SELECT tA.kArtikel, tAA.kAttribut, tAAS.cWertVarchar, tAAS.nWertInt FROM [eazybusiness].[dbo].[tArtikelEinkaufsliste] tAE
    LEFT JOIN tArtikel tA ON tA.kArtikel = tAE.kArtikel
    LEFT JOIN tArtikelAttribut tAA ON tA.kArtikel = tAA.kArtikel
    INNER JOIN tAttribut tAttr ON tAA.kAttribut = tAttr.kAttribut
    LEFT JOIN tArtikelAttributSprache tAAS ON tAA.kArtikelAttribut = tAAS.kArtikelAttribut AND tAAS.kSprache = 0
    WHERE tAA.kAttribut IN (@kAttributUnhandlich, @kAttributAktion)
),
Basis AS (
    SELECT tA.kArtikel as kArtikel, tWg.cName as Warengruppe,
           (SELECT ISNULL(A.cWertVarchar, NULL) FROM Attribute A WHERE A.kArtikel = tA.kArtikel AND A.kAttribut = @kAttributAktion) as Aktion,
           (SELECT IIF(A.nWertInt = 1, 'Unhandlich', NULL) FROM Attribute A WHERE A.kArtikel = tA.kArtikel AND A.kAttribut = @kAttributUnhandlich) as Unhandlich
    FROM [eazybusiness].[dbo].[tArtikelEinkaufsliste] tAE
    LEFT JOIN tArtikel tA ON tA.kArtikel = tAE.kArtikel
    LEFT JOIN tWarengruppe tWg ON tA.kWarengruppe = tWg.kWarengruppe
    LEFT JOIN Attribute ON tA.kArtikel = Attribute.kArtikel
)
UPDATE [eazybusiness].[dbo].[tArtikelEinkaufsliste]
  SET cHinweis = CONCAT(Basis.Warengruppe, IIF(Basis.Aktion IS NULL, '', CONCAT('; ', Basis.Aktion)), IIF(Basis.Unhandlich IS NULL, '', CONCAT('; ', Basis.Unhandlich)))
  FROM [eazybusiness].[dbo].[tArtikelEinkaufsliste] tAE
      LEFT JOIN Basis ON Basis.kArtikel = tAE.kArtikel
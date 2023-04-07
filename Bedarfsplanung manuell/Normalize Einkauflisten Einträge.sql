UPDATE [eazybusiness].[dbo].[tArtikelEinkaufsliste]
  SET kWarenlager = 17
  WHERE kWarenlager = 0


UPDATE [eazybusiness].[dbo].[tArtikelEinkaufsliste]
  SET cHinweis = tWg.cName
  FROM [eazybusiness].[dbo].[tArtikelEinkaufsliste] tAE
  LEFT JOIN tArtikel tA ON tA.kArtikel = tAE.kArtikel
  LEFT JOIN tWarengruppe tWg ON tA.kWarengruppe = tWg.kWarengruppe
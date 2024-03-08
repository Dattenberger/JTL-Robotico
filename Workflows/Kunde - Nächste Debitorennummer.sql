SELECT MAX(nDebitorennr) + 1
    FROM DbeS.vKunde vK
    WHERE vK.cKundenNr != 'Intern'
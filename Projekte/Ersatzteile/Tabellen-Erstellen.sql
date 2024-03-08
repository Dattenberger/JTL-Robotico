use ersatzteile;

BEGIN TRY
    BEGIN TRANSACTION
        CREATE TABLE [tGeraetetyp]
        (
            [kGeraeteTyp]   INT NOT NULL IDENTITY PRIMARY KEY,
            [cBezeichnung]  NVARCHAR(510),
            [cBeschreibung] NVARCHAR(MAX),
            [bRowversion]   ROWVERSION
        );

        CREATE TABLE [tHersteller]
        (
            [kHersteller]   INT NOT NULL IDENTITY PRIMARY KEY,
            [cBezeichnung]  NVARCHAR(510),
            [cBeschreibung] NVARCHAR(MAX),
            [bRowversion]   ROWVERSION
        );

        CREATE TABLE [tModell]
        (
            [kModell]       INT NOT NULL IDENTITY PRIMARY KEY,
            [kGeraeteTyp]   INT,
            [kHersteller]   INT,
            [cBezeichnung]  NVARCHAR(510),
            [cBeschreibung] NVARCHAR(MAX),
            [bRowversion]   ROWVERSION,
            CONSTRAINT [FK_tModell.kGeraeteTyp]
                FOREIGN KEY ([kGeraeteTyp])
                    REFERENCES [tGeraetetyp] ([kGeraeteTyp]),
            CONSTRAINT [FK_tModell.kHersteller]
                FOREIGN KEY ([kHersteller])
                    REFERENCES [tHersteller] ([kHersteller])
        );

        CREATE TABLE [tStatusBezeichnung]
        (
            [kStatusBezeichnung] INT NOT NULL IDENTITY PRIMARY KEY,
            [kBezeichnung]       NVARCHAR(510),
            [bRowversion]        ROWVERSION
        );

        CREATE TABLE [tSpectrum]
        (
            [kSpectrum]     INT NOT NULL IDENTITY PRIMARY KEY,
            [cBezeichnung]  NVARCHAR(510),
            [cBeschreibung] NVARCHAR(MAX),
            [bRowversion]   ROWVERSION
        );

        CREATE TABLE [tTeileliste]
        (
            [kTeileliste]   INT NOT NULL IDENTITY PRIMARY KEY,
            [kModell]       INT,
            [kSpectrum]     INT,
            [cBezeichnung]  NVARCHAR(510),
            [cBeschreibung] NVARCHAR(MAX),
            [bRowversion]   ROWVERSION,
            CONSTRAINT [FK_tTeileliste.kModell]
                FOREIGN KEY ([kModell])
                    REFERENCES [tModell] ([kModell]),
            CONSTRAINT [FK_tTeileliste.kSpectrum]
                FOREIGN KEY ([kSpectrum])
                    REFERENCES [tSpectrum] ([kSpectrum])
        );

        CREATE TABLE [tBild]
        (
            [kBild]        INT NOT NULL IDENTITY PRIMARY KEY,
            [cPath]        NVARCHAR(510),
            [kBezeichnung] NVARCHAR(510),
            [bRowversion]  ROWVERSION
        );

        CREATE TABLE [tTeil]
        (
            [kTeil]          INT NOT NULL IDENTITY PRIMARY KEY,
            [kJtlArtikel]    INT,
            [fUVPNetto]      DECIMAL(25, 13),
            [fEkNetto]       DECIMAL(25, 13),
            [cEAN]           NVARCHAR(510),
            [cHAN]           NVARCHAR(510),
            [gewichtKg]      DECIMAL(25, 13),
            [cBezeichnung]   NVARCHAR(510),
            [cBeschreibung]  NVARCHAR(MAX),
            [cTaricCode]     NVARCHAR(510),
            [cHerkungtsland] NVARCHAR(510),
            [imgUrl]         INT,
            [bRowversion]    TIMESTAMP
        );

        CREATE TABLE [tTeilelistenTeil]
        (
            [kTeilelistenTeil]   INT NOT NULL IDENTITY PRIMARY KEY,
            [kTeileliste]        INT,
            [kTeil]              INT,
            [cHAN]               NVARCHAR(510),
            [cBezeichnung]       NVARCHAR(510),
            [cBezeichnungZusatz] NVARCHAR(510),
            [cFinden]            NVARCHAR(510),
            [nAnzahl]            INT,
            [bRowversion]        ROWVERSION,
            CONSTRAINT [FK_tTeilelistenTeil.kTeileliste]
                FOREIGN KEY ([kTeileliste])
                    REFERENCES [tTeileliste] ([kTeileliste]),
            CONSTRAINT [FK_tTeilelistenTeil.kTeil]
                FOREIGN KEY ([kTeil])
                    REFERENCES [tTeil] ([kTeil])
        );

        CREATE TABLE [tHAN]
        (
            [kHANID]        INT NOT NULL IDENTITY PRIMARY KEY,
            [kErsetztDruch] INT,
            [kTeil]         INT,
            [cHAN]          NVARCHAR(510),
            [eEAN]          NVARCHAR(510),
            [bRowversion]   ROWVERSION,
            CONSTRAINT [FK_tHAN.kErsetztDruch]
                FOREIGN KEY ([kErsetztDruch])
                    REFERENCES [tHAN] ([kHANID]),
            CONSTRAINT [FK_tHAN.kHANID]
                FOREIGN KEY ([kHANID])
                    REFERENCES [tTeil] ([kTeil])
        );

        CREATE TABLE [tBildTeil]
        (
            [kBildArtikel] INT NOT NULL IDENTITY PRIMARY KEY,
            [kBild]        INT,
            [kTeil]        INT,
            [bRowversion]  ROWVERSION,
            CONSTRAINT [FK_tBildTeil.kTeil]
                FOREIGN KEY ([kTeil])
                    REFERENCES [tTeil] ([kTeil]),
            CONSTRAINT [FK_tBildTeil.kBild]
                FOREIGN KEY ([kBild])
                    REFERENCES [tBild] ([kBild])
        );

        CREATE TABLE [tStatus]
        (
            [kTeil]              INT NOT NULL IDENTITY PRIMARY KEY,
            [kStatusBezeichnung] INT,
            [kBezeichnung]       NVARCHAR(510),
            [bRowversion]        NVARCHAR(510)
        );

        CREATE TABLE [tTempVorgang]
        (
            [kVorgang]      INT NOT NULL IDENTITY PRIMARY KEY,
            [cBezeichnung]  NVARCHAR(510),
            [cBeschreibung] NVARCHAR(MAX),
            [bRowversion]   ROWVERSION
        );

        CREATE TABLE [tBildTemp]
        (
            [kBild]        INT NOT NULL IDENTITY PRIMARY KEY,
            [cPath]        NVARCHAR(510),
            [kBezeichnung] NVARCHAR(510),
            [kVorgang]     INT,
            [bRowversion]  ROWVERSION,
            CONSTRAINT [FK_tBildTemp.kVorgang]
                FOREIGN KEY ([kVorgang])
                    REFERENCES [tTempVorgang] ([kVorgang])
        );

        CREATE TABLE [tTeilTemp]
        (
            [kTeil]          INT NOT NULL IDENTITY PRIMARY KEY,
            [kJtlArtikel]    INT,
            [fUVPNetto]      DECIMAL(25, 13),
            [fEkNetto]       DECIMAL(25, 13),
            [cEAN]           NVARCHAR(510),
            [cHAN]           NVARCHAR(510),
            [gewichtKg]      DECIMAL(25, 13),
            [cBezeichnung]   NVARCHAR(510),
            [cBeschreibung]  NVARCHAR(MAX),
            [cTaricCode]     NVARCHAR(510),
            [cHerkungtsland] NVARCHAR(510),
            [imgUrl]         INT,
            [kVorgang]       INT,
            [bRowversion]    TIMESTAMP,
            CONSTRAINT [FK_tTeilTemp.kVorgang]
                FOREIGN KEY ([kVorgang])
                    REFERENCES [tTempVorgang] ([kVorgang])
        );

        CREATE TABLE [tBildTeilTemp]
        (
            [kBildArtikel] INT NOT NULL IDENTITY PRIMARY KEY,
            [kTeil]        INT,
            [kBild]        INT,
            [kVorgang]     INT,
            [bRowversion]  ROWVERSION,
            CONSTRAINT [FK_tBildTeilTemp.kVorgang]
                FOREIGN KEY ([kVorgang])
                    REFERENCES [tTempVorgang] ([kVorgang]),
            CONSTRAINT [FK_tBildTeilTemp.kBild]
                FOREIGN KEY ([kBild])
                    REFERENCES [tBildTemp] ([kBild]),
            CONSTRAINT [FK_tBildTeilTemp.kTeil]
                FOREIGN KEY ([kTeil])
                    REFERENCES [tTeilTemp] ([kTeil])
        );

        CREATE TABLE [tStatusBezeichnungTemp]
        (
            [kStatusBezeichnung] INT NOT NULL IDENTITY PRIMARY KEY,
            [kBezeichnung]       NVARCHAR(510),
            [kVorgang]           INT,
            [bRowversion]        ROWVERSION,
            CONSTRAINT [FK_tStatusBezeichnungTemp.kVorgang]
                FOREIGN KEY ([kVorgang])
                    REFERENCES [tTempVorgang] ([kVorgang])
        );

        CREATE TABLE [tStatusTempTemp]
        (
            [kTeil]              INT NOT NULL IDENTITY PRIMARY KEY,
            [kStatusBezeichnung] INT,
            [kBezeichnung]       NVARCHAR(510),
            [kVorgang]           INT,
            [bRowversion]        NVARCHAR(510)
        );

        CREATE TABLE [tHANTemp]
        (
            [kHANID]        INT NOT NULL IDENTITY PRIMARY KEY,
            [kErsetztDruch] INT,
            [kTeil]         INT,
            [cHAN]          NVARCHAR(510),
            [eEAN]          NVARCHAR(510),
            [kVorgang]      INT,
            [bRowversion]   ROWVERSION,
            CONSTRAINT [FK_tHANTemp.kErsetztDruch]
                FOREIGN KEY ([kErsetztDruch])
                    REFERENCES [tHANTemp] ([kHANID]),
            CONSTRAINT [FK_tHANTemp.kHANID]
                FOREIGN KEY ([kHANID])
                    REFERENCES [tTeilTemp] ([kTeil]),
            CONSTRAINT [FK_tHANTemp.kVorgang]
                FOREIGN KEY ([kVorgang])
                    REFERENCES [tTempVorgang] ([kVorgang])
        );

        CREATE TABLE [tSpectrumTemp]
        (
            [kSpectrum]     INT NOT NULL IDENTITY PRIMARY KEY,
            [cBezeichnung]  NVARCHAR(510),
            [cBeschreibung] NVARCHAR(MAX),
            [kVorgang]      INT,
            [bRowversion]   ROWVERSION,
            CONSTRAINT [FK_tSpectrumTemp.kVorgang]
                FOREIGN KEY ([kVorgang])
                    REFERENCES [tTempVorgang] ([kVorgang])
        );

        CREATE TABLE [tHerstellerTemp]
        (
            [kHersteller]   INT NOT NULL IDENTITY PRIMARY KEY,
            [cBezeichnung]  NVARCHAR(510),
            [cBeschreibung] NVARCHAR(MAX),
            [kVorgang]      INT,
            [bRowversion]   ROWVERSION,
            CONSTRAINT [FK_tHerstellerTemp.kVorgang]
                FOREIGN KEY ([kVorgang])
                    REFERENCES [tTempVorgang] ([kVorgang])
        );

        CREATE TABLE [tGeraetetypTemp]
        (
            [kGeraeteTyp]   INT NOT NULL IDENTITY PRIMARY KEY,
            [cBezeichnung]  NVARCHAR(510),
            [cBeschreibung] NVARCHAR(MAX),
            [kVorgang]      INT,
            [bRowversion]   ROWVERSION,
            CONSTRAINT [FK_tGeraetetypTemp.kVorgang]
                FOREIGN KEY ([kVorgang])
                    REFERENCES [tTempVorgang] ([kVorgang])
        );

        CREATE TABLE [tModellTemp]
        (
            [kModell]       INT NOT NULL IDENTITY PRIMARY KEY,
            [kGeraeteTyp]   INT,
            [kHersteller]   INT,
            [cBezeichnung]  NVARCHAR(510),
            [cBeschreibung] NVARCHAR(MAX),
            [kVorgang]      INT,
            [bRowversion]   ROWVERSION,
            CONSTRAINT [FK_tModellTemp.kHersteller]
                FOREIGN KEY ([kHersteller])
                    REFERENCES [tHerstellerTemp] ([kHersteller]),
            CONSTRAINT [FK_tModellTemp.kGeraeteTyp]
                FOREIGN KEY ([kGeraeteTyp])
                    REFERENCES [tGeraetetypTemp] ([kGeraeteTyp]),
            CONSTRAINT [FK_tModellTemp.kVorgang]
                FOREIGN KEY ([kVorgang])
                    REFERENCES [tTempVorgang] ([kVorgang])
        );

        CREATE TABLE [tTeilelisteTemp]
        (
            [kTeileliste]   INT NOT NULL IDENTITY PRIMARY KEY,
            [kModell]       INT,
            [kSpectrum]     INT,
            [cBezeichnung]  NVARCHAR(510),
            [cBeschreibung] NVARCHAR(MAX),
            [kVorgang]      INT,
            [bRowversion]   ROWVERSION,
            CONSTRAINT [FK_tTeilelisteTemp.kModell]
                FOREIGN KEY ([kModell])
                    REFERENCES [tModellTemp] ([kModell]),
            CONSTRAINT [FK_tTeilelisteTemp.kSpectrum]
                FOREIGN KEY ([kSpectrum])
                    REFERENCES [tSpectrumTemp] ([kSpectrum]),
            CONSTRAINT [FK_tTeilelisteTemp.kVorgang]
                FOREIGN KEY ([kVorgang])
                    REFERENCES [tTempVorgang] ([kVorgang])
        );

        CREATE TABLE [tTeilelistenTeilTemp]
        (
            [kTeilelistenTeil]   INT NOT NULL IDENTITY PRIMARY KEY,
            [kTeileliste]        INT,
            [kTeil]              INT,
            [cHAN]               NVARCHAR(510),
            [cBezeichnung]       NVARCHAR(510),
            [cBezeichnungZusatz] NVARCHAR(510),
            [cFinden]            NVARCHAR(510),
            [nAnzahl]            INT,
            [kVorgang]           INT,
            [bRowversion]        ROWVERSION,
            CONSTRAINT [FK_tTeilelistenTeilTemp.kTeil]
                FOREIGN KEY ([kTeil])
                    REFERENCES [tTeilTemp] ([kTeil]),
            CONSTRAINT [FK_tTeilelistenTeilTemp.kTeileliste]
                FOREIGN KEY ([kTeileliste])
                    REFERENCES [tTeilelisteTemp] ([kTeileliste]),
            CONSTRAINT [FK_tTeilelistenTeilTemp.kVorgang]
                FOREIGN KEY ([kVorgang])
                    REFERENCES [tTempVorgang] ([kVorgang])
        );


    --ROLLBACK TRANSACTION;


    COMMIT TRAN -- Transaction Success!
END TRY
BEGIN CATCH
    IF @@TRANCOUNT > 0
        ROLLBACK TRAN
    --RollBack in case of Error

    -- <EDIT>: From SQL2008 on, you must raise error messages as follows:
    DECLARE @ErrorMessage NVARCHAR(4000);
    DECLARE @ErrorSeverity INT;
    DECLARE @ErrorState INT;

    SELECT @ErrorMessage = ERROR_MESSAGE(),
           @ErrorSeverity = ERROR_SEVERITY(),
           @ErrorState = ERROR_STATE();

    RAISERROR (@ErrorMessage, @ErrorSeverity, @ErrorState);
    -- </EDIT>
END CATCH
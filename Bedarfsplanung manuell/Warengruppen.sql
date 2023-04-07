/****** Script for SelectTopNRows command from SSMS  ******/
SELECT TOP (1000) [kWarengruppe]
      ,[cName]
      ,[bRowversion]
  FROM [eazybusiness].[dbo].[tWarengruppe]
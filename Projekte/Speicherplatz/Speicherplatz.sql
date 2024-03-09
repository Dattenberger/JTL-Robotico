--Databases
SELECT DB_NAME()                                                           AS DbName,
       name                                                                AS FileName,
       size / 128.0                                                        AS CurrentSizeMB,
       size / 128.0 - CAST(FILEPROPERTY(name, 'SpaceUsed') AS INT) / 128.0 AS FreeSpaceMB
FROM sys.database_files;


Create TABLE #TableSize
(
    TableName  VARCHAR(200),
    Rows       VARCHAR(20),
    Reserved   VARCHAR(20),
    Data       VARCHAR(20),
    index_size VARCHAR(20),
    Unused     VARCHAR(20)
)
exec sp_MSForEachTable 'Insert Into #TableSize Exec sp_spaceused [?]'

--Tables
Select TableName,
       CAST(Rows AS bigint)                               As Rows,
       CONVERT(bigint, left(Reserved, len(reserved) - 3)) As Size_In_KB
from #TableSize
order by 3 desc
Drop Table #TableSize
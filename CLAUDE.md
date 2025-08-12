# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Repository Overview

JTL is our ERP System. This repository contains management scripts for a German e-commerce business called "JTL Robotico" (focuses on robotic mowers/equipment). The database is named "eazybusiness" and uses Microsoft SQL Server.

## Directory Structure

- **A_Context/JTL 1.10.11.0/**: Core JTL ERP system database schema files (version 1.10.11.0)
  - Schema definitions for major modules: Amazon, Artikel (Articles), Verkauf (Sales), Beschaffung (Procurement), WMS (Warehouse Management), etc.
  - Contains tables, views, stored procedures, and user-defined functions
  - **Important: These are context-only files providing database structure reference - do not modify these files**
- **Alt/**: Legacy/archived SQL scripts and older versions
- **Auswertungen/**: Business analysis and reporting queries
- **Druckvorlagen/**: Print template queries for documents like pick lists
- **EigenÜbersichten/**: Custom overview queries
- **PayPal/**: PayPal integration scripts
- **Projekte/**: Project-specific SQL scripts  
- **WorkflowProcedures/**: Custom workflow automation procedures
- **Workflows/**: Business workflow definitions

## Database Architecture

The system uses a multi-schema approach with German naming conventions:

### Core Schemas
- **Amazon**: Amazon marketplace integration
- **Artikel**: Product/article management
- **Verkauf**: Sales management
- **Beschaffung**: Procurement and purchasing
- **WMS**: Warehouse Management System
- **Bestand**: Inventory management
- **Versand**: Shipping management
- **CustomWorkflows**: Custom business logic
- **BI**: Business Intelligence views

### Key Business Objects
- Articles/Products (Artikel)
- Orders (Aufträge)
- Customers (Kunden)
- Suppliers (Lieferanten) 
- Inventory (Bestand)
- Pick lists (Picklisten)

## Development Workflow

This repository contains SQL scripts only - no build processes, package managers, or testing frameworks are present. Scripts are executed directly against the SQL Server database.

### File Naming Conventions
- Schema creation: `[SchemaName].Schema.sql`
- Tables: `[SchemaName].[TableName].Table.sql`  
- Views: `[SchemaName].[ViewName].View.sql`
- Stored Procedures: `[SchemaName].[ProcName].StoredProcedure.sql`
- Functions: `[SchemaName].[FunctionName].UserDefinedFunction.sql`

### Key Considerations
- All scripts use German language for comments and identifiers
- Database target is Microsoft SQL Server
- Uses JTL-WaWi ERP system conventions
- UTF-8 BOM encoding in files (visible as special characters at start)
- Custom workflows extend base JTL functionality

## Important Notes

- The system manages e-commerce operations including Amazon marketplace integration
- Contains sensitive business logic for inventory, pricing, and order management
- Scripts include workflow procedures for automation (e.g., setting order prices to zero for internal orders)
- Uses extensive view-based architecture for data access abstraction
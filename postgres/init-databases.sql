-- Runs once, when the postgres volume is created. One database per service; Flyway in each service creates the tables.
CREATE DATABASE auth;
CREATE DATABASE profile;
CREATE DATABASE catalog;
CREATE DATABASE metric;

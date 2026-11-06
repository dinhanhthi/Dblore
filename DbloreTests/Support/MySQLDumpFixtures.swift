//
//  MySQLDumpFixtures.swift
//  DbloreTests
//
//  Real dump files, kept byte for byte: `mysqldump --skip-dump-date qa_b12_dump` from MySQL 8.4
//  and `mariadb-dump --skip-dump-date qa_b12_dump` from MariaDB 11.4 (default options, no
//  `--databases`). Two tables: an int key, a varchar with an emoji and escaped quotes, a decimal,
//  a double with an exponent, a blob and a bit (ASCII-only bytes, so the files stay UTF-8), a
//  date and a NULL. `mysqlDumpWithGTID` adds the lines `--set-gtid-purged=ON` writes after the
//  header (GTID is off on the test server), for the refusal case.
//

enum MySQLDumpFixtures {
  static let mysqlDump = #"""
    -- MySQL dump 10.13  Distrib 8.4.11, for Linux (aarch64)
    --
    -- Host: localhost    Database: qa_b12_dump
    -- ------------------------------------------------------
    -- Server version	8.4.11

    /*!40101 SET @OLD_CHARACTER_SET_CLIENT=@@CHARACTER_SET_CLIENT */;
    /*!40101 SET @OLD_CHARACTER_SET_RESULTS=@@CHARACTER_SET_RESULTS */;
    /*!40101 SET @OLD_COLLATION_CONNECTION=@@COLLATION_CONNECTION */;
    /*!50503 SET NAMES utf8mb4 */;
    /*!40103 SET @OLD_TIME_ZONE=@@TIME_ZONE */;
    /*!40103 SET TIME_ZONE='+00:00' */;
    /*!40014 SET @OLD_UNIQUE_CHECKS=@@UNIQUE_CHECKS, UNIQUE_CHECKS=0 */;
    /*!40014 SET @OLD_FOREIGN_KEY_CHECKS=@@FOREIGN_KEY_CHECKS, FOREIGN_KEY_CHECKS=0 */;
    /*!40101 SET @OLD_SQL_MODE=@@SQL_MODE, SQL_MODE='NO_AUTO_VALUE_ON_ZERO' */;
    /*!40111 SET @OLD_SQL_NOTES=@@SQL_NOTES, SQL_NOTES=0 */;

    --
    -- Table structure for table `items`
    --

    DROP TABLE IF EXISTS `items`;
    /*!40101 SET @saved_cs_client     = @@character_set_client */;
    /*!50503 SET character_set_client = utf8mb4 */;
    CREATE TABLE `items` (
      `id` int NOT NULL,
      `name` varchar(50) DEFAULT NULL,
      `price` decimal(10,3) DEFAULT NULL,
      `ratio` double DEFAULT NULL,
      `data` blob,
      `flags` bit(8) DEFAULT NULL,
      `made` date DEFAULT NULL,
      `note` varchar(20) DEFAULT NULL,
      PRIMARY KEY (`id`)
    ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci;
    /*!40101 SET character_set_client = @saved_cs_client */;

    --
    -- Dumping data for table `items`
    --

    LOCK TABLES `items` WRITE;
    /*!40000 ALTER TABLE `items` DISABLE KEYS */;
    INSERT INTO `items` VALUES (1,'apple 🍎',1234.567,0.00000000015,_binary '\0A\n\'',_binary '!','2026-11-05',NULL),(2,'it\'s \"q\" \\ back',-0.001,-2.25e30,_binary '\\\"A',_binary 'A','1999-12-31','n');
    /*!40000 ALTER TABLE `items` ENABLE KEYS */;
    UNLOCK TABLES;

    --
    -- Table structure for table `tags`
    --

    DROP TABLE IF EXISTS `tags`;
    /*!40101 SET @saved_cs_client     = @@character_set_client */;
    /*!50503 SET character_set_client = utf8mb4 */;
    CREATE TABLE `tags` (
      `id` int NOT NULL,
      `item_id` int DEFAULT NULL,
      `tag` varchar(20) DEFAULT NULL,
      PRIMARY KEY (`id`),
      KEY `k_item` (`item_id`)
    ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci;
    /*!40101 SET character_set_client = @saved_cs_client */;

    --
    -- Dumping data for table `tags`
    --

    LOCK TABLES `tags` WRITE;
    /*!40000 ALTER TABLE `tags` DISABLE KEYS */;
    INSERT INTO `tags` VALUES (10,1,'fruit'),(11,2,'odd');
    /*!40000 ALTER TABLE `tags` ENABLE KEYS */;
    UNLOCK TABLES;
    /*!40103 SET TIME_ZONE=@OLD_TIME_ZONE */;

    /*!40101 SET SQL_MODE=@OLD_SQL_MODE */;
    /*!40014 SET FOREIGN_KEY_CHECKS=@OLD_FOREIGN_KEY_CHECKS */;
    /*!40014 SET UNIQUE_CHECKS=@OLD_UNIQUE_CHECKS */;
    /*!40101 SET CHARACTER_SET_CLIENT=@OLD_CHARACTER_SET_CLIENT */;
    /*!40101 SET CHARACTER_SET_RESULTS=@OLD_CHARACTER_SET_RESULTS */;
    /*!40101 SET COLLATION_CONNECTION=@OLD_COLLATION_CONNECTION */;
    /*!40111 SET SQL_NOTES=@OLD_SQL_NOTES */;

    -- Dump completed

    """#

  static let mariaDBDump = #"""
    /*M!999999\- enable the sandbox mode */ 
    -- MariaDB dump 10.19-11.4.13-MariaDB, for debian-linux-gnu (aarch64)
    --
    -- Host: localhost    Database: qa_b12_dump
    -- ------------------------------------------------------
    -- Server version	11.4.13-MariaDB-ubu2404

    /*!40101 SET @OLD_CHARACTER_SET_CLIENT=@@CHARACTER_SET_CLIENT */;
    /*!40101 SET @OLD_CHARACTER_SET_RESULTS=@@CHARACTER_SET_RESULTS */;
    /*!40101 SET @OLD_COLLATION_CONNECTION=@@COLLATION_CONNECTION */;
    /*!40101 SET NAMES utf8mb4 */;
    /*!40103 SET @OLD_TIME_ZONE=@@TIME_ZONE */;
    /*!40103 SET TIME_ZONE='+00:00' */;
    /*!40014 SET @OLD_UNIQUE_CHECKS=@@UNIQUE_CHECKS, UNIQUE_CHECKS=0 */;
    /*!40014 SET @OLD_FOREIGN_KEY_CHECKS=@@FOREIGN_KEY_CHECKS, FOREIGN_KEY_CHECKS=0 */;
    /*!40101 SET @OLD_SQL_MODE=@@SQL_MODE, SQL_MODE='NO_AUTO_VALUE_ON_ZERO' */;
    /*M!100616 SET @OLD_NOTE_VERBOSITY=@@NOTE_VERBOSITY, NOTE_VERBOSITY=0 */;

    --
    -- Table structure for table `items`
    --

    DROP TABLE IF EXISTS `items`;
    /*!40101 SET @saved_cs_client     = @@character_set_client */;
    /*!40101 SET character_set_client = utf8mb4 */;
    CREATE TABLE `items` (
      `id` int(11) NOT NULL,
      `name` varchar(50) DEFAULT NULL,
      `price` decimal(10,3) DEFAULT NULL,
      `ratio` double DEFAULT NULL,
      `data` blob DEFAULT NULL,
      `flags` bit(8) DEFAULT NULL,
      `made` date DEFAULT NULL,
      `note` varchar(20) DEFAULT NULL,
      PRIMARY KEY (`id`)
    ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_uca1400_ai_ci;
    /*!40101 SET character_set_client = @saved_cs_client */;

    --
    -- Dumping data for table `items`
    --

    LOCK TABLES `items` WRITE;
    /*!40000 ALTER TABLE `items` DISABLE KEYS */;
    INSERT INTO `items` VALUES
    (1,'apple 🍎',1234.567,0.00000000015,'\0A\n\'','!','2026-11-05',NULL),
    (2,'it\'s \"q\" \\ back',-0.001,-2.25e30,'\\\"A','A','1999-12-31','n');
    /*!40000 ALTER TABLE `items` ENABLE KEYS */;
    UNLOCK TABLES;

    --
    -- Table structure for table `tags`
    --

    DROP TABLE IF EXISTS `tags`;
    /*!40101 SET @saved_cs_client     = @@character_set_client */;
    /*!40101 SET character_set_client = utf8mb4 */;
    CREATE TABLE `tags` (
      `id` int(11) NOT NULL,
      `item_id` int(11) DEFAULT NULL,
      `tag` varchar(20) DEFAULT NULL,
      PRIMARY KEY (`id`),
      KEY `k_item` (`item_id`)
    ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_uca1400_ai_ci;
    /*!40101 SET character_set_client = @saved_cs_client */;

    --
    -- Dumping data for table `tags`
    --

    LOCK TABLES `tags` WRITE;
    /*!40000 ALTER TABLE `tags` DISABLE KEYS */;
    INSERT INTO `tags` VALUES
    (10,1,'fruit'),
    (11,2,'odd');
    /*!40000 ALTER TABLE `tags` ENABLE KEYS */;
    UNLOCK TABLES;
    /*!40103 SET TIME_ZONE=@OLD_TIME_ZONE */;

    /*!40101 SET SQL_MODE=@OLD_SQL_MODE */;
    /*!40014 SET FOREIGN_KEY_CHECKS=@OLD_FOREIGN_KEY_CHECKS */;
    /*!40014 SET UNIQUE_CHECKS=@OLD_UNIQUE_CHECKS */;
    /*!40101 SET CHARACTER_SET_CLIENT=@OLD_CHARACTER_SET_CLIENT */;
    /*!40101 SET CHARACTER_SET_RESULTS=@OLD_CHARACTER_SET_RESULTS */;
    /*!40101 SET COLLATION_CONNECTION=@OLD_COLLATION_CONNECTION */;
    /*M!100616 SET NOTE_VERBOSITY=@OLD_NOTE_VERBOSITY */;

    -- Dump completed

    """#

  static let mysqlDumpWithGTID = #"""
    -- MySQL dump 10.13  Distrib 8.4.11, for Linux (aarch64)
    --
    -- Host: localhost    Database: qa_b12_dump
    -- ------------------------------------------------------
    -- Server version	8.4.11

    /*!40101 SET @OLD_CHARACTER_SET_CLIENT=@@CHARACTER_SET_CLIENT */;
    /*!40101 SET @OLD_CHARACTER_SET_RESULTS=@@CHARACTER_SET_RESULTS */;
    /*!40101 SET @OLD_COLLATION_CONNECTION=@@COLLATION_CONNECTION */;
    /*!50503 SET NAMES utf8mb4 */;
    /*!40103 SET @OLD_TIME_ZONE=@@TIME_ZONE */;
    /*!40103 SET TIME_ZONE='+00:00' */;
    /*!40014 SET @OLD_UNIQUE_CHECKS=@@UNIQUE_CHECKS, UNIQUE_CHECKS=0 */;
    /*!40014 SET @OLD_FOREIGN_KEY_CHECKS=@@FOREIGN_KEY_CHECKS, FOREIGN_KEY_CHECKS=0 */;
    /*!40101 SET @OLD_SQL_MODE=@@SQL_MODE, SQL_MODE='NO_AUTO_VALUE_ON_ZERO' */;
    SET @MYSQLDUMP_TEMP_LOG_BIN = @@SESSION.SQL_LOG_BIN;
    SET @@SESSION.SQL_LOG_BIN= 0;

    --
    -- GTID state at the beginning of the backup 
    --

    SET @@GLOBAL.GTID_PURGED=/*!80000 '+'*/ '3e11fa47-71ca-11e1-9e33-c80aa9429562:1-5';
    /*!40111 SET @OLD_SQL_NOTES=@@SQL_NOTES, SQL_NOTES=0 */;

    --
    -- Table structure for table `items`
    --

    DROP TABLE IF EXISTS `items`;
    /*!40101 SET @saved_cs_client     = @@character_set_client */;
    /*!50503 SET character_set_client = utf8mb4 */;
    CREATE TABLE `items` (
      `id` int NOT NULL,
      `name` varchar(50) DEFAULT NULL,
      `price` decimal(10,3) DEFAULT NULL,
      `ratio` double DEFAULT NULL,
      `data` blob,
      `flags` bit(8) DEFAULT NULL,
      `made` date DEFAULT NULL,
      `note` varchar(20) DEFAULT NULL,
      PRIMARY KEY (`id`)
    ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci;
    /*!40101 SET character_set_client = @saved_cs_client */;

    --
    -- Dumping data for table `items`
    --

    LOCK TABLES `items` WRITE;
    /*!40000 ALTER TABLE `items` DISABLE KEYS */;
    INSERT INTO `items` VALUES (1,'apple 🍎',1234.567,0.00000000015,_binary '\0A\n\'',_binary '!','2026-11-05',NULL),(2,'it\'s \"q\" \\ back',-0.001,-2.25e30,_binary '\\\"A',_binary 'A','1999-12-31','n');
    /*!40000 ALTER TABLE `items` ENABLE KEYS */;
    UNLOCK TABLES;

    --
    -- Table structure for table `tags`
    --

    DROP TABLE IF EXISTS `tags`;
    /*!40101 SET @saved_cs_client     = @@character_set_client */;
    /*!50503 SET character_set_client = utf8mb4 */;
    CREATE TABLE `tags` (
      `id` int NOT NULL,
      `item_id` int DEFAULT NULL,
      `tag` varchar(20) DEFAULT NULL,
      PRIMARY KEY (`id`),
      KEY `k_item` (`item_id`)
    ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci;
    /*!40101 SET character_set_client = @saved_cs_client */;

    --
    -- Dumping data for table `tags`
    --

    LOCK TABLES `tags` WRITE;
    /*!40000 ALTER TABLE `tags` DISABLE KEYS */;
    INSERT INTO `tags` VALUES (10,1,'fruit'),(11,2,'odd');
    /*!40000 ALTER TABLE `tags` ENABLE KEYS */;
    UNLOCK TABLES;
    /*!40103 SET TIME_ZONE=@OLD_TIME_ZONE */;

    /*!40101 SET SQL_MODE=@OLD_SQL_MODE */;
    /*!40014 SET FOREIGN_KEY_CHECKS=@OLD_FOREIGN_KEY_CHECKS */;
    /*!40014 SET UNIQUE_CHECKS=@OLD_UNIQUE_CHECKS */;
    /*!40101 SET CHARACTER_SET_CLIENT=@OLD_CHARACTER_SET_CLIENT */;
    /*!40101 SET CHARACTER_SET_RESULTS=@OLD_CHARACTER_SET_RESULTS */;
    /*!40101 SET COLLATION_CONNECTION=@OLD_COLLATION_CONNECTION */;
    /*!40111 SET SQL_NOTES=@OLD_SQL_NOTES */;

    -- Dump completed

    """#
}

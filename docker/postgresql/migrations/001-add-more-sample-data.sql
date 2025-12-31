-- Migration: Add more sample data to all tables
-- Purpose: Expand dataset for comprehensive testing of SQLNotebook

-- =============================================================================
-- MORE CUSTOMERS (adding 20 more)
-- =============================================================================
INSERT INTO customers (first_name, last_name, email, phone, metadata) VALUES
('Patricia', 'Anderson', 'patricia.a@example.com', '+1-555-0201', '{"preferences": {"newsletter": true, "notifications": "email"}, "tier": "silver", "interests": ["electronics", "gadgets"]}'),
('Christopher', 'Thomas', 'chris.thomas@example.com', '+1-555-0202', '{"preferences": {"newsletter": true, "notifications": "both"}, "tier": "platinum", "vip": true}'),
('Amanda', 'Martinez', 'amanda.m@example.com', '+1-555-0203', '{"preferences": {"newsletter": false, "notifications": "sms"}, "tier": "bronze"}'),
('Matthew', 'Garcia', 'matthew.g@example.com', '+1-555-0204', '{"preferences": {"newsletter": true, "notifications": "email"}, "tier": "gold", "birthday": "1985-06-15"}'),
('Ashley', 'Rodriguez', 'ashley.r@example.com', '+1-555-0205', '{"preferences": {"newsletter": true, "notifications": "email"}, "tier": "silver"}'),
('Daniel', 'Lopez', 'daniel.lopez@example.com', '+1-555-0206', '{"preferences": {"newsletter": false, "notifications": "none"}, "tier": "bronze"}'),
('Stephanie', 'Lee', 'stephanie.lee@example.com', '+1-555-0207', '{"preferences": {"newsletter": true, "notifications": "sms"}, "tier": "gold", "referral_code": "STEPH2024"}'),
('Kevin', 'Walker', 'kevin.walker@example.com', '+1-555-0208', '{"preferences": {"newsletter": true, "notifications": "both"}, "tier": "platinum"}'),
('Michelle', 'Hall', 'michelle.hall@example.com', '+1-555-0209', '{"preferences": {"newsletter": true, "notifications": "email"}, "tier": "silver"}'),
('Brian', 'Allen', 'brian.allen@example.com', '+1-555-0210', '{"preferences": {"newsletter": false, "notifications": "email"}, "tier": "gold"}'),
('Nicole', 'Young', 'nicole.young@example.com', '+1-555-0211', '{"preferences": {"newsletter": true, "notifications": "sms"}, "tier": "bronze"}'),
('Ryan', 'King', 'ryan.king@example.com', '+1-555-0212', '{"preferences": {"newsletter": true, "notifications": "both"}, "tier": "platinum", "corporate": true}'),
('Laura', 'Wright', 'laura.wright@example.com', '+1-555-0213', '{"preferences": {"newsletter": true, "notifications": "email"}, "tier": "silver"}'),
('Brandon', 'Scott', 'brandon.scott@example.com', '+1-555-0214', '{"preferences": {"newsletter": false, "notifications": "none"}, "tier": "bronze"}'),
('Melissa', 'Green', 'melissa.green@example.com', '+1-555-0215', '{"preferences": {"newsletter": true, "notifications": "email"}, "tier": "gold"}'),
('Jason', 'Adams', 'jason.adams@example.com', '+1-555-0216', '{"preferences": {"newsletter": true, "notifications": "sms"}, "tier": "silver"}'),
('Rebecca', 'Baker', 'rebecca.baker@example.com', '+1-555-0217', '{"preferences": {"newsletter": true, "notifications": "both"}, "tier": "platinum", "anniversary": "2020-01-15"}'),
('Gary', 'Nelson', 'gary.nelson@example.com', '+1-555-0218', '{"preferences": {"newsletter": false, "notifications": "email"}, "tier": "bronze"}'),
('Kimberly', 'Carter', 'kimberly.c@example.com', '+1-555-0219', '{"preferences": {"newsletter": true, "notifications": "email"}, "tier": "gold"}'),
('Jeffrey', 'Mitchell', 'jeffrey.m@example.com', '+1-555-0220', '{"preferences": {"newsletter": true, "notifications": "both"}, "tier": "silver"}');

-- =============================================================================
-- MORE PRODUCTS (adding 25 more)
-- =============================================================================
INSERT INTO products (name, description, category, price, stock_quantity, specifications) VALUES
('Gaming Mouse', 'High-precision gaming mouse with RGB', 'Accessories', 79.99, 110, '{"dpi": 16000, "buttons": 8, "rgb": true, "wireless": true}'),
('60% Mechanical Keyboard', 'Compact mechanical keyboard for programmers', 'Accessories', 159.99, 55, '{"switches": "Cherry MX Brown", "layout": "60%", "rgb": true}'),
('4K Webcam', 'Professional 4K webcam with autofocus', 'Electronics', 199.99, 40, '{"resolution": "3840x2160", "fps": 30, "autofocus": true, "fov": "90°"}'),
('USB Microphone', 'Condenser microphone for streaming', 'Electronics', 129.99, 65, '{"polar_pattern": "Cardioid", "usb": true, "mute_button": true}'),
('Laptop Sleeve 15"', 'Waterproof laptop sleeve with pocket', 'Accessories', 24.99, 150, '{"size": "15 inch", "material": "Neoprene", "waterproof": true}'),
('Thunderbolt 4 Cable', '2m Thunderbolt 4 cable 40Gbps', 'Accessories', 44.99, 200, '{"length": "2m", "speed": "40Gbps", "power": "100W"}'),
('Monitor Arm', 'Adjustable monitor arm for dual screens', 'Furniture', 89.99, 45, '{"monitors": 2, "vesa": "75x75, 100x100", "weight_capacity": "20kg"}'),
('Ergonomic Footrest', 'Adjustable footrest for office', 'Furniture', 39.99, 75, '{"adjustable": true, "angles": 3, "surface": "textured"}'),
('Laptop Cooling Pad', 'Laptop cooler with 5 fans', 'Accessories', 34.99, 85, '{"fans": 5, "usb_powered": true, "adjustable_height": true}'),
('Graphics Tablet', 'Digital drawing tablet with pen', 'Electronics', 179.99, 35, '{"pressure_levels": 8192, "size": "10x6 inch", "wireless": false}'),
('Portable Monitor 15.6"', 'USB-C portable monitor', 'Electronics', 249.99, 50, '{"size": "15.6 inch", "resolution": "1920x1080", "usb_c": true}'),
('Docking Station', 'Universal USB-C docking station', 'Accessories', 199.99, 60, '{"ports": 12, "dual_4k": true, "power_delivery": "100W"}'),
('Smart LED Strip', 'WiFi RGB LED strip 5m', 'Electronics', 39.99, 120, '{"length": "5m", "wifi": true, "voice_control": true, "colors": "16M"}'),
('Wireless Charger', 'Fast wireless charging pad', 'Accessories', 29.99, 140, '{"wattage": "15W", "qi_certified": true, "led_indicator": true}'),
('HDMI Switch', '4K HDMI switch 5-in-1-out', 'Accessories', 34.99, 95, '{"inputs": 5, "resolution": "4K@60Hz", "hdr": true}'),
('Laptop Backpack', 'Anti-theft laptop backpack with USB', 'Accessories', 59.99, 100, '{"capacity": "30L", "usb_port": true, "waterproof": true}'),
('Ring Light', '10" ring light with tripod', 'Electronics', 49.99, 70, '{"diameter": "10 inch", "brightness_levels": 10, "tripod_height": "50cm"}'),
('Tablet Stand', 'Aluminum tablet and phone stand', 'Accessories', 27.99, 130, '{"material": "Aluminum", "angles": "adjustable", "compatible": "all tablets"}'),
('SSD 2TB', 'Internal SSD SATA 2TB', 'Electronics', 199.99, 55, '{"capacity": "2TB", "interface": "SATA III", "speed": "560 MB/s"}'),
('NVMe SSD 512GB', 'M.2 NVMe SSD 512GB', 'Electronics', 79.99, 90, '{"capacity": "512GB", "interface": "NVMe PCIe 4.0", "speed": "7000 MB/s"}'),
('Mouse Pad XL', 'Extended gaming mouse pad', 'Accessories', 19.99, 180, '{"size": "900x400mm", "material": "Cloth", "anti_slip": true}'),
('Cable Clips', 'Self-adhesive cable clips 20 pack', 'Accessories', 9.99, 250, '{"quantity": 20, "adhesive": true, "reusable": false}'),
('Desk Organizer', 'Bamboo desk organizer with drawer', 'Furniture', 44.99, 65, '{"material": "Bamboo", "compartments": 6, "drawer": true}'),
('Monitor Light Bar', 'Screen light bar for monitors', 'Electronics', 89.99, 50, '{"auto_dimming": true, "color_temperature": "2700K-6500K", "usb_powered": true}'),
('Surge Protector', '12-outlet surge protector with USB', 'Electronics', 39.99, 110, '{"outlets": 12, "usb_ports": 3, "joules": 4000}');

-- =============================================================================
-- MORE EMPLOYEES (adding 15 more)
-- =============================================================================
INSERT INTO employees (first_name, last_name, email, hire_date, salary, department, manager_id, employment_details) VALUES
('Kelly', 'Kim', 'kelly.kim@company.com', '2021-02-15', 92000, 'Engineering', 1, '{"title": "Senior Engineer", "level": "L5", "specialization": "Backend"}'),
('Nathan', 'Nash', 'nathan.nash@company.com', '2022-03-20', 78000, 'Engineering', 2, '{"title": "Engineer", "level": "L4", "specialization": "Frontend"}'),
('Olivia', 'Owen', 'olivia.owen@company.com', '2022-07-01', 72000, 'Engineering', 2, '{"title": "Junior Engineer", "level": "L3", "specialization": "QA"}'),
('Paul', 'Peterson', 'paul.p@company.com', '2021-04-10', 98000, 'Engineering', 1, '{"title": "Senior Engineer", "level": "L5", "specialization": "DevOps"}'),
('Quinn', 'Quinn', 'quinn.q@company.com', '2020-11-15', 88000, 'Engineering', 1, '{"title": "Engineer", "level": "L4", "specialization": "Full Stack"}'),
('Rachel', 'Roberts', 'rachel.r@company.com', '2021-05-20', 85000, 'Sales', 5, '{"title": "Account Manager", "level": "L4", "region": "West Coast"}'),
('Samuel', 'Stevens', 'samuel.s@company.com', '2022-01-15', 68000, 'Sales', 5, '{"title": "Sales Representative", "level": "L3", "region": "East Coast"}'),
('Tina', 'Turner', 'tina.t@company.com', '2021-09-01', 75000, 'Sales', 5, '{"title": "Account Manager", "level": "L4", "region": "Midwest"}'),
('Umar', 'Underwood', 'umar.u@company.com', '2020-06-30', 82000, 'Marketing', 8, '{"title": "Marketing Manager", "level": "L4", "focus": "Digital"}'),
('Vanessa', 'Vega', 'vanessa.v@company.com', '2021-12-01', 70000, 'Marketing', 8, '{"title": "Content Manager", "level": "L3", "focus": "Social Media"}'),
('William', 'White', 'william.w@company.com', '2022-05-15', 68000, 'Marketing', 9, '{"title": "Marketing Coordinator", "level": "L3", "focus": "Email"}'),
('Xavier', 'Xu', 'xavier.xu@company.com', '2019-08-20', 125000, 'Product', NULL, '{"title": "VP Product", "level": "L7"}'),
('Yolanda', 'Young', 'yolanda.y@company.com', '2020-10-12', 95000, 'Product', 27, '{"title": "Product Manager", "level": "L5", "products": ["Enterprise"]}'),
('Zachary', 'Zhang', 'zachary.z@company.com', '2021-07-22', 88000, 'Product', 27, '{"title": "Product Manager", "level": "L4", "products": ["Mobile"]}'),
('Angela', 'Armstrong', 'angela.a@company.com', '2022-02-28', 80000, 'Product', 27, '{"title": "Associate Product Manager", "level": "L3", "products": ["Web"]}');

-- =============================================================================
-- MORE ORDERS (adding 35 more orders)
-- =============================================================================
INSERT INTO orders (customer_id, order_date, total_amount, status, shipping_address) VALUES
-- Recent orders
(11, '2024-03-16 09:30:00', 179.99, 'delivered', '{"street": "111 Tech Blvd", "city": "Austin", "state": "TX", "zip": "78701"}'),
(12, '2024-03-17 14:20:00', 2499.95, 'shipped', '{"street": "222 Innovation Dr", "city": "Seattle", "state": "WA", "zip": "98101"}'),
(13, '2024-03-18 10:15:00', 89.97, 'delivered', '{"street": "333 Startup Ave", "city": "Denver", "state": "CO", "zip": "80201"}'),
(14, '2024-03-19 16:45:00', 449.98, 'processing', '{"street": "444 Valley Rd", "city": "Portland", "state": "OR", "zip": "97201"}'),
(15, '2024-03-20 11:00:00', 159.99, 'pending', '{"street": "555 Mountain Way", "city": "Salt Lake City", "state": "UT", "zip": "84101"}'),
(16, '2024-03-21 13:30:00', 679.96, 'shipped', '{"street": "666 Lake St", "city": "Minneapolis", "state": "MN", "zip": "55401"}'),
(17, '2024-03-22 09:45:00', 299.99, 'delivered', '{"street": "777 River Rd", "city": "Nashville", "state": "TN", "zip": "37201"}'),
(18, '2024-03-23 15:20:00', 1099.98, 'processing', '{"street": "888 Harbor Ln", "city": "Boston", "state": "MA", "zip": "02101"}'),
(19, '2024-03-24 10:30:00', 234.97, 'pending', '{"street": "999 Bridge St", "city": "Miami", "state": "FL", "zip": "33101"}'),
(20, '2024-03-25 14:15:00', 549.99, 'shipped', '{"street": "1010 Park Ave", "city": "Atlanta", "state": "GA", "zip": "30301"}'),
-- More orders for existing customers
(1, '2024-03-26 11:20:00', 199.98, 'delivered', '{"street": "123 Main St", "city": "New York", "state": "NY", "zip": "10001"}'),
(2, '2024-03-27 16:30:00', 899.97, 'processing', '{"street": "456 Oak Ave", "city": "Los Angeles", "state": "CA", "zip": "90001"}'),
(3, '2024-03-28 09:15:00', 349.99, 'shipped', '{"street": "789 Pine Rd", "city": "Chicago", "state": "IL", "zip": "60601"}'),
(11, '2024-03-29 13:45:00', 129.99, 'pending', '{"street": "111 Tech Blvd", "city": "Austin", "state": "TX", "zip": "78701"}'),
(12, '2024-03-30 10:00:00', 449.97, 'delivered', '{"street": "222 Innovation Dr", "city": "Seattle", "state": "WA", "zip": "98101"}'),
(4, '2024-04-01 14:30:00', 279.98, 'processing', '{"street": "321 Elm St", "city": "Houston", "state": "TX", "zip": "77001"}'),
(5, '2024-04-02 11:45:00', 599.98, 'shipped', '{"street": "654 Maple Dr", "city": "Phoenix", "state": "AZ", "zip": "85001"}'),
(13, '2024-04-03 15:20:00', 189.99, 'pending', '{"street": "333 Startup Ave", "city": "Denver", "state": "CO", "zip": "80201"}'),
(6, '2024-04-04 09:30:00', 999.96, 'delivered', '{"street": "987 Birch Ln", "city": "Philadelphia", "state": "PA", "zip": "19101"}'),
(14, '2024-04-05 12:15:00', 349.98, 'processing', '{"street": "444 Valley Rd", "city": "Portland", "state": "OR", "zip": "97201"}'),
(7, '2024-04-06 16:00:00', 229.98, 'shipped', '{"street": "147 Cedar Ct", "city": "San Antonio", "state": "TX", "zip": "78201"}'),
(15, '2024-04-07 10:45:00', 799.97, 'pending', '{"street": "555 Mountain Way", "city": "Salt Lake City", "state": "UT", "zip": "84101"}'),
(8, '2024-04-08 14:20:00', 159.99, 'delivered', '{"street": "258 Spruce Way", "city": "San Diego", "state": "CA", "zip": "92101"}'),
(16, '2024-04-09 11:30:00', 529.98, 'processing', '{"street": "666 Lake St", "city": "Minneapolis", "state": "MN", "zip": "55401"}'),
(9, '2024-04-10 15:45:00', 389.97, 'shipped', '{"street": "369 Willow Pl", "city": "Dallas", "state": "TX", "zip": "75201"}'),
(17, '2024-04-11 09:00:00', 249.99, 'pending', '{"street": "777 River Rd", "city": "Nashville", "state": "TN", "zip": "37201"}'),
(10, '2024-04-12 13:15:00', 679.97, 'delivered', '{"street": "741 Ash Blvd", "city": "San Jose", "state": "CA", "zip": "95101"}'),
(18, '2024-04-13 10:30:00', 299.99, 'processing', '{"street": "888 Harbor Ln", "city": "Boston", "state": "MA", "zip": "02101"}'),
(19, '2024-04-14 14:45:00', 449.98, 'shipped', '{"street": "999 Bridge St", "city": "Miami", "state": "FL", "zip": "33101"}'),
(20, '2024-04-15 11:00:00', 899.96, 'pending', '{"street": "1010 Park Ave", "city": "Atlanta", "state": "GA", "zip": "30301"}'),
-- Older orders for variety
(11, '2024-02-01 10:00:00', 599.98, 'delivered', '{"street": "111 Tech Blvd", "city": "Austin", "state": "TX", "zip": "78701"}'),
(12, '2024-02-05 14:30:00', 1299.99, 'delivered', '{"street": "222 Innovation Dr", "city": "Seattle", "state": "WA", "zip": "98101"}'),
(13, '2024-02-10 09:15:00', 349.97, 'delivered', '{"street": "333 Startup Ave", "city": "Denver", "state": "CO", "zip": "80201"}'),
(14, '2024-02-15 16:45:00', 799.98, 'delivered', '{"street": "444 Valley Rd", "city": "Portland", "state": "OR", "zip": "97201"}'),
(15, '2024-02-20 11:30:00', 249.99, 'delivered', '{"street": "555 Mountain Way", "city": "Salt Lake City", "state": "UT", "zip": "84101"}');

-- =============================================================================
-- MORE ORDER_ITEMS (for new orders)
-- =============================================================================
INSERT INTO order_items (order_id, product_id, quantity, unit_price) VALUES
-- Order 16 (Customer 11)
(16, 17, 1, 179.99),
-- Order 17 (Customer 12)
(17, 1, 1, 1299.99),
(17, 5, 1, 399.99),
(17, 16, 1, 179.99),
(17, 27, 1, 249.99),
(17, 30, 2, 179.99),
-- Order 18 (Customer 13)
(18, 2, 3, 29.99),
-- Order 19 (Customer 14)
(19, 10, 1, 299.99),
(19, 11, 1, 149.99),
-- Order 20 (Customer 15)
(20, 22, 1, 159.99),
-- Order 21 (Customer 16)
(21, 4, 1, 129.99),
(21, 10, 1, 299.99),
(21, 24, 1, 249.99),
-- Order 22 (Customer 17)
(22, 10, 1, 299.99),
-- Order 23 (Customer 18)
(23, 1, 1, 1299.99),
(23, 26, 1, 199.99),
-- Order 24 (Customer 19)
(24, 3, 1, 49.99),
(24, 20, 1, 24.99),
(24, 28, 1, 39.99),
(24, 35, 2, 59.99),
-- Order 25 (Customer 20)
(25, 16, 1, 179.99),
(25, 30, 2, 179.99),
-- Order 26 (Customer 1)
(26, 20, 2, 24.99),
(26, 11, 1, 149.99),
-- Order 27 (Customer 2)
(27, 5, 1, 399.99),
(27, 1, 1, 1299.99),
(27, 27, 1, 249.99),
-- Order 28 (Customer 3)
(28, 16, 1, 179.99),
(28, 17, 1, 179.99),
-- Order 29 (Customer 11)
(29, 18, 1, 129.99),
-- Order 30 (Customer 12)
(30, 10, 1, 299.99),
(30, 11, 1, 149.99),
-- Order 31 (Customer 4)
(31, 19, 1, 199.99),
(31, 21, 2, 39.99),
-- Order 32 (Customer 5)
(32, 5, 1, 399.99),
(32, 27, 1, 249.99),
-- Order 33 (Customer 13)
(33, 26, 1, 199.99),
-- Order 34 (Customer 6)
(34, 1, 1, 1299.99),
(34, 16, 1, 179.99),
(34, 22, 1, 159.99),
(34, 17, 1, 179.99),
(34, 30, 1, 179.99),
-- Order 35 (Customer 14)
(35, 24, 1, 249.99),
(35, 19, 1, 199.99),
-- Order 36 (Customer 7)
(36, 3, 2, 49.99),
(36, 18, 1, 129.99),
-- Order 37 (Customer 15)
(37, 1, 1, 1299.99),
(37, 5, 1, 399.99),
(37, 19, 1, 199.99),
-- Order 38 (Customer 8)
(38, 22, 1, 159.99),
-- Order 39 (Customer 16)
(39, 10, 1, 299.99),
(39, 24, 1, 249.99),
-- Order 40 (Customer 9)
(40, 7, 1, 79.99),
(40, 11, 1, 149.99),
(40, 16, 1, 179.99),
-- Order 41 (Customer 17)
(41, 24, 1, 249.99),
-- Order 42 (Customer 10)
(42, 1, 1, 1299.99),
(42, 5, 1, 399.99),
(42, 16, 1, 179.99),
-- Order 43 (Customer 18)
(43, 10, 1, 299.99),
-- Order 44 (Customer 19)
(44, 27, 1, 249.99),
(44, 30, 1, 179.99),
(44, 20, 1, 24.99),
-- Order 45 (Customer 20)
(45, 1, 1, 1299.99),
(45, 5, 1, 399.99),
(45, 27, 1, 249.99),
(45, 30, 1, 179.99),
-- Order 46 (Customer 11)
(46, 5, 1, 399.99),
(46, 27, 1, 249.99),
-- Order 47 (Customer 12)
(47, 1, 1, 1299.99),
-- Order 48 (Customer 13)
(48, 16, 1, 179.99),
(48, 17, 1, 179.99),
-- Order 49 (Customer 14)
(49, 1, 1, 1299.99),
(49, 5, 1, 399.99),
(49, 27, 1, 249.99),
-- Order 50 (Customer 15)
(50, 24, 1, 249.99);

-- =============================================================================
-- MORE ANALYTICS EVENTS (adding 35 more events)
-- =============================================================================
INSERT INTO analytics_events (event_type, event_timestamp, user_id, session_id, properties, metrics) VALUES
('page_view', '2024-03-04 08:00:00', 7, 'h8i9j0k1-l2m3-4567-hijk-lm8901234567', '{"page": "/home", "referrer": "google"}', '{"duration": 35}'),
('search', '2024-03-04 08:05:00', 7, 'h8i9j0k1-l2m3-4567-hijk-lm8901234567', '{"query": "keyboard", "results": 8}', '{"duration": 12}'),
('page_view', '2024-03-04 08:10:00', 7, 'h8i9j0k1-l2m3-4567-hijk-lm8901234567', '{"page": "/products/4", "referrer": "/search"}', '{"duration": 85}'),
('add_to_cart', '2024-03-04 08:15:00', 7, 'h8i9j0k1-l2m3-4567-hijk-lm8901234567', '{"product_id": 4, "quantity": 1}', '{"price": 129.99}'),
('page_view', '2024-03-05 09:00:00', 8, 'i9j0k1l2-m3n4-5678-ijkl-mn9012345678', '{"page": "/home", "referrer": "instagram"}', '{"duration": 50}'),
('page_view', '2024-03-05 09:05:00', 8, 'i9j0k1l2-m3n4-5678-ijkl-mn9012345678', '{"page": "/products", "referrer": "/home"}', '{"duration": 140}'),
('add_to_cart', '2024-03-05 09:15:00', 8, 'i9j0k1l2-m3n4-5678-ijkl-mn9012345678', '{"product_id": 9, "quantity": 1}', '{"price": 249.99}'),
('checkout', '2024-03-05 09:20:00', 8, 'i9j0k1l2-m3n4-5678-ijkl-mn9012345678', '{"items": 1, "total": 249.99}', '{"duration": 150}'),
('purchase', '2024-03-05 09:25:00', 8, 'i9j0k1l2-m3n4-5678-ijkl-mn9012345678', '{"order_id": 7, "total": 249.99}', '{"revenue": 249.99}'),
('page_view', '2024-03-06 10:00:00', 9, 'j0k1l2m3-n4o5-6789-jklm-no0123456789', '{"page": "/products/1", "referrer": "youtube"}', '{"duration": 95}'),
('add_to_cart', '2024-03-06 10:10:00', 9, 'j0k1l2m3-n4o5-6789-jklm-no0123456789', '{"product_id": 1, "quantity": 1}', '{"price": 1299.99}'),
('page_view', '2024-03-06 10:15:00', 9, 'j0k1l2m3-n4o5-6789-jklm-no0123456789', '{"page": "/products/5", "referrer": "/cart"}', '{"duration": 70}'),
('add_to_cart', '2024-03-06 10:20:00', 9, 'j0k1l2m3-n4o5-6789-jklm-no0123456789', '{"product_id": 5, "quantity": 1}', '{"price": 399.99}'),
('checkout', '2024-03-06 10:25:00', 9, 'j0k1l2m3-n4o5-6789-jklm-no0123456789', '{"items": 2, "total": 1699.98}', '{"duration": 200}'),
('page_view', '2024-03-07 11:00:00', 10, 'k1l2m3n4-o5p6-7890-klmn-op1234567890', '{"page": "/home", "referrer": "linkedin"}', '{"duration": 42}'),
('search', '2024-03-07 11:05:00', 10, 'k1l2m3n4-o5p6-7890-klmn-op1234567890', '{"query": "monitor", "results": 4}', '{"duration": 18}'),
('page_view', '2024-03-07 11:10:00', 10, 'k1l2m3n4-o5p6-7890-klmn-op1234567890', '{"page": "/products/5", "referrer": "/search"}', '{"duration": 105}'),
('page_view', '2024-03-08 12:00:00', 11, 'l2m3n4o5-p6q7-8901-lmno-pq2345678901', '{"page": "/home", "referrer": "reddit"}', '{"duration": 38}'),
('page_view', '2024-03-08 12:05:00', 11, 'l2m3n4o5-p6q7-8901-lmno-pq2345678901', '{"page": "/deals", "referrer": "/home"}', '{"duration": 160}'),
('add_to_cart', '2024-03-08 12:15:00', 11, 'l2m3n4o5-p6q7-8901-lmno-pq2345678901', '{"product_id": 17, "quantity": 1}', '{"price": 179.99}'),
('purchase', '2024-03-08 12:20:00', 11, 'l2m3n4o5-p6q7-8901-lmno-pq2345678901', '{"order_id": 16, "total": 179.99}', '{"revenue": 179.99}'),
('page_view', '2024-03-09 13:00:00', 12, 'm3n4o5p6-q7r8-9012-mnop-qr3456789012', '{"page": "/products", "referrer": "pinterest"}', '{"duration": 180}'),
('search', '2024-03-09 13:10:00', 12, 'm3n4o5p6-q7r8-9012-mnop-qr3456789012', '{"query": "gaming", "results": 12}', '{"duration": 25}'),
('page_view', '2024-03-09 13:15:00', 12, 'm3n4o5p6-q7r8-9012-mnop-qr3456789012', '{"page": "/products/16", "referrer": "/search"}', '{"duration": 120}'),
('add_to_cart', '2024-03-09 13:25:00', 12, 'm3n4o5p6-q7r8-9012-mnop-qr3456789012', '{"product_id": 1, "quantity": 1}', '{"price": 1299.99}'),
('add_to_cart', '2024-03-09 13:30:00', 12, 'm3n4o5p6-q7r8-9012-mnop-qr3456789012', '{"product_id": 16, "quantity": 1}', '{"price": 179.99}'),
('page_view', '2024-03-10 14:00:00', 13, 'n4o5p6q7-r8s9-0123-nopq-rs4567890123', '{"page": "/home", "referrer": "tiktok"}', '{"duration": 28}'),
('page_view', '2024-03-10 14:05:00', 13, 'n4o5p6q7-r8s9-0123-nopq-rs4567890123', '{"page": "/categories/accessories", "referrer": "/home"}', '{"duration": 95}'),
('add_to_cart', '2024-03-10 14:15:00', 13, 'n4o5p6q7-r8s9-0123-nopq-rs4567890123', '{"product_id": 2, "quantity": 3}', '{"price": 29.99}'),
('page_view', '2024-03-11 15:00:00', 14, 'o5p6q7r8-s9t0-1234-opqr-st5678901234', '{"page": "/products/10", "referrer": "google"}', '{"duration": 110}'),
('add_to_cart', '2024-03-11 15:10:00', 14, 'o5p6q7r8-s9t0-1234-opqr-st5678901234', '{"product_id": 10, "quantity": 1}', '{"price": 299.99}'),
('add_to_cart', '2024-03-11 15:15:00', 14, 'o5p6q7r8-s9t0-1234-opqr-st5678901234', '{"product_id": 11, "quantity": 1}', '{"price": 149.99}'),
('checkout', '2024-03-11 15:20:00', 14, 'o5p6q7r8-s9t0-1234-opqr-st5678901234', '{"items": 2, "total": 449.98}', '{"duration": 165}'),
('page_view', '2024-03-12 16:00:00', 15, 'p6q7r8s9-t0u1-2345-pqrs-tu6789012345', '{"page": "/home", "referrer": "direct"}', '{"duration": 45}'),
('page_view', '2024-03-12 16:05:00', 15, 'p6q7r8s9-t0u1-2345-pqrs-tu6789012345', '{"page": "/products/22", "referrer": "/home"}', '{"duration": 80}');

-- =============================================================================
-- SUMMARY
-- =============================================================================
DO $$
DECLARE
    v_customers INTEGER;
    v_products INTEGER;
    v_orders INTEGER;
    v_order_items INTEGER;
    v_employees INTEGER;
    v_analytics INTEGER;
BEGIN
    SELECT COUNT(*) INTO v_customers FROM customers;
    SELECT COUNT(*) INTO v_products FROM products;
    SELECT COUNT(*) INTO v_orders FROM orders;
    SELECT COUNT(*) INTO v_order_items FROM order_items;
    SELECT COUNT(*) INTO v_employees FROM employees;
    SELECT COUNT(*) INTO v_analytics FROM analytics_events;

    RAISE NOTICE '=============================================================================';
    RAISE NOTICE 'Migration 001: Additional Sample Data Applied Successfully!';
    RAISE NOTICE '=============================================================================';
    RAISE NOTICE 'Total Records After Migration:';
    RAISE NOTICE '  - Customers: %', v_customers;
    RAISE NOTICE '  - Products: %', v_products;
    RAISE NOTICE '  - Orders: %', v_orders;
    RAISE NOTICE '  - Order Items: %', v_order_items;
    RAISE NOTICE '  - Employees: %', v_employees;
    RAISE NOTICE '  - Analytics Events: %', v_analytics;
    RAISE NOTICE '=============================================================================';
END $$;

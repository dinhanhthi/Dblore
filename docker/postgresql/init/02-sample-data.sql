-- SQLNotebook Sample Data - Extended Version
-- This script populates the database with comprehensive example data for testing

-- =============================================================================
-- CUSTOMERS (30 records)
-- =============================================================================
INSERT INTO customers (first_name, last_name, email, phone, metadata) VALUES
('John', 'Doe', 'john.doe@example.com', '+1-555-0101', '{"preferences": {"newsletter": true, "notifications": "email"}, "tier": "gold"}'),
('Jane', 'Smith', 'jane.smith@example.com', '+1-555-0102', '{"preferences": {"newsletter": false, "notifications": "sms"}, "tier": "silver"}'),
('Robert', 'Johnson', 'robert.j@example.com', '+1-555-0103', '{"preferences": {"newsletter": true, "notifications": "both"}, "tier": "platinum"}'),
('Emily', 'Williams', 'emily.w@example.com', '+1-555-0104', '{"preferences": {"newsletter": true, "notifications": "email"}, "tier": "bronze"}'),
('Michael', 'Brown', 'michael.b@example.com', '+1-555-0105', '{"preferences": {"newsletter": false, "notifications": "none"}, "tier": "silver"}'),
('Sarah', 'Davis', 'sarah.davis@example.com', '+1-555-0106', '{"preferences": {"newsletter": true, "notifications": "email"}, "tier": "gold"}'),
('David', 'Miller', 'david.miller@example.com', '+1-555-0107', '{"preferences": {"newsletter": true, "notifications": "sms"}, "tier": "bronze"}'),
('Lisa', 'Wilson', 'lisa.wilson@example.com', '+1-555-0108', '{"preferences": {"newsletter": false, "notifications": "email"}, "tier": "platinum"}'),
('James', 'Moore', 'james.moore@example.com', '+1-555-0109', '{"preferences": {"newsletter": true, "notifications": "both"}, "tier": "gold"}'),
('Jennifer', 'Taylor', 'jennifer.t@example.com', '+1-555-0110', '{"preferences": {"newsletter": true, "notifications": "email"}, "tier": "silver"}'),
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
-- PRODUCTS (40 records)
-- =============================================================================
INSERT INTO products (name, description, category, price, stock_quantity, specifications) VALUES
('Laptop Pro 15', 'High-performance laptop with 15-inch display', 'Electronics', 1299.99, 45, '{"cpu": "Intel i7", "ram": "16GB", "storage": "512GB SSD", "screen": "15.6 inch"}'),
('Wireless Mouse', 'Ergonomic wireless mouse with 6 buttons', 'Accessories', 29.99, 150, '{"connectivity": "Bluetooth", "battery": "AA", "dpi": 1600}'),
('USB-C Hub', '7-in-1 USB-C hub with HDMI and SD card reader', 'Accessories', 49.99, 80, '{"ports": 7, "hdmi": "4K@60Hz", "usb": "USB 3.0"}'),
('Mechanical Keyboard', 'RGB mechanical keyboard with Cherry MX switches', 'Accessories', 129.99, 60, '{"switches": "Cherry MX Red", "rgb": true, "wireless": false}'),
('27" Monitor', '4K UHD monitor with HDR support', 'Electronics', 399.99, 30, '{"resolution": "3840x2160", "refresh_rate": "60Hz", "panel": "IPS"}'),
('Laptop Stand', 'Adjustable aluminum laptop stand', 'Accessories', 39.99, 120, '{"material": "Aluminum", "adjustable": true, "color": "Silver"}'),
('Webcam HD', '1080p webcam with built-in microphone', 'Electronics', 79.99, 75, '{"resolution": "1920x1080", "fps": 30, "microphone": true}'),
('Desk Lamp', 'LED desk lamp with USB charging port', 'Furniture', 34.99, 90, '{"brightness_levels": 5, "color_temperature": "adjustable", "usb_port": true}'),
('Office Chair', 'Ergonomic office chair with lumbar support', 'Furniture', 249.99, 25, '{"adjustable_height": true, "lumbar_support": true, "material": "Mesh"}'),
('Noise-Cancelling Headphones', 'Premium wireless headphones with ANC', 'Electronics', 299.99, 50, '{"wireless": true, "anc": true, "battery_life": "30 hours"}'),
('Portable SSD 1TB', 'Fast portable SSD with USB-C', 'Electronics', 149.99, 100, '{"capacity": "1TB", "interface": "USB-C", "speed": "1050 MB/s"}'),
('Phone Stand', 'Adjustable phone and tablet stand', 'Accessories', 19.99, 200, '{"compatible": "all devices", "adjustable": true, "foldable": true}'),
('Cable Organizer', 'Desk cable management system', 'Accessories', 14.99, 180, '{"slots": 5, "material": "Silicone", "adhesive": true}'),
('Power Bank 20000mAh', 'High-capacity portable charger', 'Electronics', 59.99, 85, '{"capacity": "20000mAh", "ports": 2, "fast_charge": true}'),
('Bluetooth Speaker', 'Waterproof portable Bluetooth speaker', 'Electronics', 69.99, 95, '{"waterproof": "IPX7", "battery": "12 hours", "bluetooth": "5.0"}'),
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
-- EMPLOYEES (25 records)
-- =============================================================================
INSERT INTO employees (first_name, last_name, email, hire_date, salary, department, manager_id, employment_details) VALUES
('Alice', 'Anderson', 'alice.a@company.com', '2020-01-15', 120000, 'Engineering', NULL, '{"title": "VP Engineering", "level": "L7"}'),
('Bob', 'Baker', 'bob.b@company.com', '2020-03-01', 95000, 'Engineering', 1, '{"title": "Senior Engineer", "level": "L5"}'),
('Charlie', 'Clark', 'charlie.c@company.com', '2021-06-15', 85000, 'Engineering', 1, '{"title": "Engineer", "level": "L4"}'),
('Diana', 'Davis', 'diana.d@company.com', '2022-01-10', 75000, 'Engineering', 2, '{"title": "Junior Engineer", "level": "L3"}'),
('Eve', 'Evans', 'eve.e@company.com', '2019-05-20', 110000, 'Sales', NULL, '{"title": "VP Sales", "level": "L7"}'),
('Frank', 'Foster', 'frank.f@company.com', '2020-08-12', 80000, 'Sales', 5, '{"title": "Account Manager", "level": "L4"}'),
('Grace', 'Green', 'grace.g@company.com', '2021-11-01', 70000, 'Sales', 5, '{"title": "Sales Representative", "level": "L3"}'),
('Henry', 'Harris', 'henry.h@company.com', '2018-03-15', 105000, 'Marketing', NULL, '{"title": "VP Marketing", "level": "L7"}'),
('Iris', 'Irwin', 'iris.i@company.com', '2020-09-30', 75000, 'Marketing', 8, '{"title": "Marketing Manager", "level": "L4"}'),
('Jack', 'Jackson', 'jack.j@company.com', '2022-04-01', 65000, 'Marketing', 8, '{"title": "Marketing Coordinator", "level": "L3"}'),
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
('Yolanda', 'Young', 'yolanda.y@company.com', '2020-10-12', 95000, 'Product', 22, '{"title": "Product Manager", "level": "L5", "products": ["Enterprise"]}'),
('Zachary', 'Zhang', 'zachary.z@company.com', '2021-07-22', 88000, 'Product', 22, '{"title": "Product Manager", "level": "L4", "products": ["Mobile"]}'),
('Angela', 'Armstrong', 'angela.a@company.com', '2022-02-28', 80000, 'Product', 22, '{"title": "Associate Product Manager", "level": "L3", "products": ["Web"]}');

-- =============================================================================
-- ORDERS (50 records)
-- =============================================================================
INSERT INTO orders (customer_id, order_date, total_amount, status, shipping_address) VALUES
(1, '2024-01-15 10:30:00', 1329.98, 'delivered', '{"street": "123 Main St", "city": "New York", "state": "NY", "zip": "10001"}'),
(1, '2024-02-20 14:15:00', 49.99, 'delivered', '{"street": "123 Main St", "city": "New York", "state": "NY", "zip": "10001"}'),
(2, '2024-01-18 09:45:00', 429.98, 'delivered', '{"street": "456 Oak Ave", "city": "Los Angeles", "state": "CA", "zip": "90001"}'),
(3, '2024-02-05 16:20:00', 1699.97, 'shipped', '{"street": "789 Pine Rd", "city": "Chicago", "state": "IL", "zip": "60601"}'),
(4, '2024-02-10 11:00:00', 79.98, 'delivered', '{"street": "321 Elm St", "city": "Houston", "state": "TX", "zip": "77001"}'),
(5, '2024-02-15 13:30:00', 299.99, 'processing', '{"street": "654 Maple Dr", "city": "Phoenix", "state": "AZ", "zip": "85001"}'),
(6, '2024-02-18 10:15:00', 249.99, 'shipped', '{"street": "987 Birch Ln", "city": "Philadelphia", "state": "PA", "zip": "19101"}'),
(7, '2024-02-22 15:45:00', 159.97, 'pending', '{"street": "147 Cedar Ct", "city": "San Antonio", "state": "TX", "zip": "78201"}'),
(8, '2024-02-25 09:00:00', 1949.96, 'processing', '{"street": "258 Spruce Way", "city": "San Diego", "state": "CA", "zip": "92101"}'),
(9, '2024-03-01 12:30:00', 549.97, 'pending', '{"street": "369 Willow Pl", "city": "Dallas", "state": "TX", "zip": "75201"}'),
(10, '2024-03-05 14:00:00', 89.98, 'delivered', '{"street": "741 Ash Blvd", "city": "San Jose", "state": "CA", "zip": "95101"}'),
(2, '2024-03-08 11:20:00', 299.99, 'shipped', '{"street": "456 Oak Ave", "city": "Los Angeles", "state": "CA", "zip": "90001"}'),
(3, '2024-03-10 16:45:00', 149.99, 'pending', '{"street": "789 Pine Rd", "city": "Chicago", "state": "IL", "zip": "60601"}'),
(1, '2024-03-12 10:00:00', 699.98, 'processing', '{"street": "123 Main St", "city": "New York", "state": "NY", "zip": "10001"}'),
(5, '2024-03-15 13:15:00', 199.98, 'pending', '{"street": "654 Maple Dr", "city": "Phoenix", "state": "AZ", "zip": "85001"}'),
(11, '2024-03-16 09:30:00', 179.99, 'delivered', '{"street": "111 Tech Blvd", "city": "Austin", "state": "TX", "zip": "78701"}'),
(12, '2024-03-17 14:20:00', 2079.95, 'shipped', '{"street": "222 Innovation Dr", "city": "Seattle", "state": "WA", "zip": "98101"}'),
(13, '2024-03-18 10:15:00', 89.97, 'delivered', '{"street": "333 Startup Ave", "city": "Denver", "state": "CO", "zip": "80201"}'),
(14, '2024-03-19 16:45:00', 449.98, 'processing', '{"street": "444 Valley Rd", "city": "Portland", "state": "OR", "zip": "97201"}'),
(15, '2024-03-20 11:00:00', 159.99, 'pending', '{"street": "555 Mountain Way", "city": "Salt Lake City", "state": "UT", "zip": "84101"}'),
(16, '2024-03-21 13:30:00', 679.96, 'shipped', '{"street": "666 Lake St", "city": "Minneapolis", "state": "MN", "zip": "55401"}'),
(17, '2024-03-22 09:45:00', 299.99, 'delivered', '{"street": "777 River Rd", "city": "Nashville", "state": "TN", "zip": "37201"}'),
(18, '2024-03-23 15:20:00', 1679.97, 'processing', '{"street": "888 Harbor Ln", "city": "Boston", "state": "MA", "zip": "02101"}'),
(19, '2024-03-24 10:30:00', 234.96, 'pending', '{"street": "999 Bridge St", "city": "Miami", "state": "FL", "zip": "33101"}'),
(20, '2024-03-25 14:15:00', 539.98, 'shipped', '{"street": "1010 Park Ave", "city": "Atlanta", "state": "GA", "zip": "30301"}'),
(1, '2024-03-26 11:20:00', 199.98, 'delivered', '{"street": "123 Main St", "city": "New York", "state": "NY", "zip": "10001"}'),
(2, '2024-03-27 16:30:00', 1869.96, 'processing', '{"street": "456 Oak Ave", "city": "Los Angeles", "state": "CA", "zip": "90001"}'),
(3, '2024-03-28 09:15:00', 359.98, 'shipped', '{"street": "789 Pine Rd", "city": "Chicago", "state": "IL", "zip": "60601"}'),
(11, '2024-03-29 13:45:00', 129.99, 'pending', '{"street": "111 Tech Blvd", "city": "Austin", "state": "TX", "zip": "78701"}'),
(12, '2024-03-30 10:00:00', 449.97, 'delivered', '{"street": "222 Innovation Dr", "city": "Seattle", "state": "WA", "zip": "98101"}'),
(4, '2024-04-01 14:30:00', 279.98, 'processing', '{"street": "321 Elm St", "city": "Houston", "state": "TX", "zip": "77001"}'),
(5, '2024-04-02 11:45:00', 649.98, 'shipped', '{"street": "654 Maple Dr", "city": "Phoenix", "state": "AZ", "zip": "85001"}'),
(13, '2024-04-03 15:20:00', 199.99, 'pending', '{"street": "333 Startup Ave", "city": "Denver", "state": "CO", "zip": "80201"}'),
(6, '2024-04-04 09:30:00', 1919.95, 'delivered', '{"street": "987 Birch Ln", "city": "Philadelphia", "state": "PA", "zip": "19101"}'),
(14, '2024-04-05 12:15:00', 449.98, 'processing', '{"street": "444 Valley Rd", "city": "Portland", "state": "OR", "zip": "97201"}'),
(7, '2024-04-06 16:00:00', 229.98, 'shipped', '{"street": "147 Cedar Ct", "city": "San Antonio", "state": "TX", "zip": "78201"}'),
(15, '2024-04-07 10:45:00', 1879.95, 'pending', '{"street": "555 Mountain Way", "city": "Salt Lake City", "state": "UT", "zip": "84101"}'),
(8, '2024-04-08 14:20:00', 159.99, 'delivered', '{"street": "258 Spruce Way", "city": "San Diego", "state": "CA", "zip": "92101"}'),
(16, '2024-04-09 11:30:00', 549.98, 'processing', '{"street": "666 Lake St", "city": "Minneapolis", "state": "MN", "zip": "55401"}'),
(9, '2024-04-10 15:45:00', 409.97, 'shipped', '{"street": "369 Willow Pl", "city": "Dallas", "state": "TX", "zip": "75201"}'),
(17, '2024-04-11 09:00:00', 249.99, 'pending', '{"street": "777 River Rd", "city": "Nashville", "state": "TN", "zip": "37201"}'),
(10, '2024-04-12 13:15:00', 708.96, 'delivered', '{"street": "741 Ash Blvd", "city": "San Jose", "state": "CA", "zip": "95101"}'),
(18, '2024-04-13 10:30:00', 299.99, 'processing', '{"street": "888 Harbor Ln", "city": "Boston", "state": "MA", "zip": "02101"}'),
(19, '2024-04-14 14:45:00', 474.97, 'shipped', '{"street": "999 Bridge St", "city": "Miami", "state": "FL", "zip": "33101"}'),
(20, '2024-04-15 11:00:00', 1957.95, 'pending', '{"street": "1010 Park Ave", "city": "Atlanta", "state": "GA", "zip": "30301"}'),
(11, '2024-02-01 10:00:00', 649.98, 'delivered', '{"street": "111 Tech Blvd", "city": "Austin", "state": "TX", "zip": "78701"}'),
(12, '2024-02-05 14:30:00', 1299.99, 'delivered', '{"street": "222 Innovation Dr", "city": "Seattle", "state": "WA", "zip": "98101"}'),
(13, '2024-02-10 09:15:00', 359.98, 'delivered', '{"street": "333 Startup Ave", "city": "Denver", "state": "CO", "zip": "80201"}'),
(14, '2024-02-15 16:45:00', 1879.95, 'delivered', '{"street": "444 Valley Rd", "city": "Portland", "state": "OR", "zip": "97201"}'),
(15, '2024-02-20 11:30:00', 249.99, 'delivered', '{"street": "555 Mountain Way", "city": "Salt Lake City", "state": "UT", "zip": "84101"}');

-- =============================================================================
-- ORDER_ITEMS (100+ records)
-- =============================================================================
INSERT INTO order_items (order_id, product_id, quantity, unit_price) VALUES
-- Order 1-15 (original)
(1, 1, 1, 1299.99), (1, 2, 1, 29.99),
(2, 3, 1, 49.99),
(3, 5, 1, 399.99), (3, 2, 1, 29.99),
(4, 1, 1, 1299.99), (4, 5, 1, 399.99),
(5, 7, 1, 79.99),
(6, 10, 1, 299.99),
(7, 9, 1, 249.99),
(8, 11, 1, 149.99), (8, 12, 1, 19.99), (8, 13, 1, 14.99),
(9, 1, 1, 1299.99), (9, 5, 1, 399.99), (9, 9, 1, 249.99),
(10, 4, 1, 129.99), (10, 3, 1, 49.99), (10, 10, 1, 299.99), (10, 7, 1, 79.99),
(11, 2, 3, 29.99),
(12, 10, 1, 299.99),
(13, 11, 1, 149.99),
(14, 5, 1, 399.99), (14, 10, 1, 299.99),
(15, 14, 2, 59.99), (15, 15, 2, 69.99),
-- Order 16-50 (new)
(16, 25, 1, 179.99),
(17, 1, 1, 1299.99), (17, 5, 1, 399.99), (17, 16, 1, 179.99), (17, 27, 1, 199.99),
(18, 2, 3, 29.99),
(19, 10, 1, 299.99), (19, 11, 1, 149.99),
(20, 17, 1, 159.99),
(21, 4, 1, 129.99), (21, 10, 1, 299.99), (21, 24, 1, 249.99),
(22, 10, 1, 299.99),
(23, 1, 1, 1299.99), (23, 34, 1, 199.99), (23, 16, 1, 179.99),
(24, 3, 1, 49.99), (24, 20, 1, 24.99), (24, 23, 1, 39.99), (24, 35, 2, 79.99),
(25, 25, 1, 179.99), (25, 26, 1, 249.99), (25, 19, 1, 129.99),
(26, 20, 2, 24.99), (26, 11, 1, 149.99),
(27, 5, 1, 399.99), (27, 1, 1, 1299.99), (27, 17, 1, 159.99),
(28, 16, 1, 179.99), (28, 17, 1, 159.99),
(29, 19, 1, 129.99),
(30, 10, 1, 299.99), (30, 11, 1, 149.99),
(31, 34, 1, 199.99), (31, 21, 2, 39.99),
(32, 5, 1, 399.99), (32, 27, 1, 249.99),
(33, 34, 1, 199.99),
(34, 1, 1, 1299.99), (34, 16, 1, 179.99), (34, 17, 1, 159.99), (34, 18, 1, 199.99), (34, 19, 1, 129.99),
(35, 24, 1, 249.99), (35, 34, 1, 199.99),
(36, 3, 2, 49.99), (36, 18, 1, 129.99),
(37, 1, 1, 1299.99), (37, 5, 1, 399.99), (37, 16, 1, 179.99),
(38, 17, 1, 159.99),
(39, 10, 1, 299.99), (39, 24, 1, 249.99),
(40, 7, 1, 79.99), (40, 11, 1, 149.99), (40, 16, 1, 179.99),
(41, 24, 1, 249.99),
(42, 1, 1, 1299.99), (42, 5, 1, 399.99), (42, 19, 1, 129.99),
(43, 10, 1, 299.99),
(44, 27, 1, 249.99), (44, 26, 1, 249.99), (44, 20, 1, 24.99),
(45, 1, 1, 1299.99), (45, 5, 1, 399.99), (45, 27, 1, 249.99), (45, 19, 1, 129.99),
(46, 5, 1, 399.99), (46, 24, 1, 249.99),
(47, 1, 1, 1299.99),
(48, 16, 1, 179.99), (48, 17, 1, 159.99),
(49, 1, 1, 1299.99), (49, 5, 1, 399.99), (49, 16, 1, 179.99),
(50, 24, 1, 249.99);

-- =============================================================================
-- ANALYTICS EVENTS (50 records)
-- =============================================================================
INSERT INTO analytics_events (event_type, event_timestamp, user_id, session_id, properties, metrics) VALUES
('page_view', '2024-03-01 08:00:00', 1, 'a1b2c3d4-e5f6-7890-abcd-ef1234567890', '{"page": "/home", "referrer": "google"}', '{"duration": 45}'),
('page_view', '2024-03-01 08:05:00', 1, 'a1b2c3d4-e5f6-7890-abcd-ef1234567890', '{"page": "/products", "referrer": "/home"}', '{"duration": 120}'),
('add_to_cart', '2024-03-01 08:10:00', 1, 'a1b2c3d4-e5f6-7890-abcd-ef1234567890', '{"product_id": 1, "quantity": 1}', '{"price": 1299.99}'),
('checkout', '2024-03-01 08:15:00', 1, 'a1b2c3d4-e5f6-7890-abcd-ef1234567890', '{"items": 1, "total": 1299.99}', '{"duration": 180}'),
('purchase', '2024-03-01 08:20:00', 1, 'a1b2c3d4-e5f6-7890-abcd-ef1234567890', '{"order_id": 1, "total": 1299.99}', '{"duration": 1299.99}'),
('page_view', '2024-03-01 09:00:00', 2, 'b2c3d4e5-16a7-8901-bcde-f12345678901', '{"page": "/home", "referrer": "facebook"}', '{"duration": 30}'),
('search', '2024-03-01 09:05:00', 2, 'b2c3d4e5-16a7-8901-bcde-f12345678901', '{"query": "laptop", "results": 5}', '{"duration": 15}'),
('page_view', '2024-03-01 09:10:00', 3, 'c3d4e5f6-a7b8-9012-cdef-123456789012', '{"page": "/products/1", "referrer": "direct"}', '{"duration": 90}'),
('add_to_cart', '2024-03-01 09:15:00', 3, 'c3d4e5f6-a7b8-9012-cdef-123456789012', '{"product_id": 5, "quantity": 1}', '{"price": 399.99}'),
('page_view', '2024-03-01 10:00:00', 4, 'd4e5f6a7-b8c9-0123-de11-114567890123', '{"page": "/home", "referrer": "twitter"}', '{"duration": 60}'),
('page_view', '2024-03-02 08:00:00', 1, 'e5f6a7b8-c9d0-1234-ef11-115678901234', '{"page": "/home", "referrer": "direct"}', '{"duration": 40}'),
('page_view', '2024-03-02 10:30:00', 5, 'f6a7b8c9-d0e1-2345-1111-116789012345', '{"page": "/products", "referrer": "google"}', '{"duration": 150}'),
('search', '2024-03-02 10:35:00', 5, 'f6a7b8c9-d0e1-2345-1111-116789012345', '{"query": "headphones", "results": 3}', '{"duration": 10}'),
('add_to_cart', '2024-03-02 10:40:00', 5, 'f6a7b8c9-d0e1-2345-1111-116789012345', '{"product_id": 10, "quantity": 1}', '{"price": 299.99}'),
('page_view', '2024-03-03 14:00:00', 6, 'a7b8c9d0-e1f2-3456-1111-117890123456', '{"page": "/home", "referrer": "email"}', '{"duration": 55}'),
('page_view', '2024-03-04 08:00:00', 7, 'b8c9d0e1-f2a3-4567-1111-118901234567', '{"page": "/home", "referrer": "google"}', '{"duration": 35}'),
('search', '2024-03-04 08:05:00', 7, 'b8c9d0e1-f2a3-4567-1111-118901234567', '{"query": "keyboard", "results": 8}', '{"duration": 12}'),
('page_view', '2024-03-04 08:10:00', 7, 'b8c9d0e1-f2a3-4567-1111-118901234567', '{"page": "/products/4", "referrer": "/search"}', '{"duration": 85}'),
('add_to_cart', '2024-03-04 08:15:00', 7, 'b8c9d0e1-f2a3-4567-1111-118901234567', '{"product_id": 4, "quantity": 1}', '{"price": 129.99}'),
('page_view', '2024-03-05 09:00:00', 8, 'c9d0e1f2-a3b4-5678-1111-119012345678', '{"page": "/home", "referrer": "instagram"}', '{"duration": 50}'),
('page_view', '2024-03-05 09:05:00', 8, 'c9d0e1f2-a3b4-5678-1111-119012345678', '{"page": "/products", "referrer": "/home"}', '{"duration": 140}'),
('add_to_cart', '2024-03-05 09:15:00', 8, 'c9d0e1f2-a3b4-5678-1111-119012345678', '{"product_id": 9, "quantity": 1}', '{"price": 249.99}'),
('checkout', '2024-03-05 09:20:00', 8, 'c9d0e1f2-a3b4-5678-1111-119012345678', '{"items": 1, "total": 249.99}', '{"duration": 150}'),
('purchase', '2024-03-05 09:25:00', 8, 'c9d0e1f2-a3b4-5678-1111-119012345678', '{"order_id": 7, "total": 249.99}', '{"revenue": 249.99}'),
('page_view', '2024-03-06 10:00:00', 9, 'd0e1f2a3-b4c5-6789-1111-000123456789', '{"page": "/products/1", "referrer": "youtube"}', '{"duration": 95}'),
('add_to_cart', '2024-03-06 10:10:00', 9, 'd0e1f2a3-b4c5-6789-1111-000123456789', '{"product_id": 1, "quantity": 1}', '{"price": 1299.99}'),
('page_view', '2024-03-06 10:15:00', 9, 'd0e1f2a3-b4c5-6789-1111-000123456789', '{"page": "/products/5", "referrer": "/cart"}', '{"duration": 70}'),
('add_to_cart', '2024-03-06 10:20:00', 9, 'd0e1f2a3-b4c5-6789-1111-000123456789', '{"product_id": 5, "quantity": 1}', '{"price": 399.99}'),
('checkout', '2024-03-06 10:25:00', 9, 'd0e1f2a3-b4c5-6789-1111-000123456789', '{"items": 2, "total": 1699.98}', '{"duration": 200}'),
('page_view', '2024-03-07 11:00:00', 10, 'e1f2a3b4-c5d6-7890-1111-001234567890', '{"page": "/home", "referrer": "linkedin"}', '{"duration": 42}'),
('search', '2024-03-07 11:05:00', 10, 'e1f2a3b4-c5d6-7890-1111-001234567890', '{"query": "monitor", "results": 4}', '{"duration": 18}'),
('page_view', '2024-03-07 11:10:00', 10, 'e1f2a3b4-c5d6-7890-1111-001234567890', '{"page": "/products/5", "referrer": "/search"}', '{"duration": 105}'),
('page_view', '2024-03-08 12:00:00', 11, 'f2a3b4c5-d6e7-8901-1111-002345678901', '{"page": "/home", "referrer": "reddit"}', '{"duration": 38}'),
('page_view', '2024-03-08 12:05:00', 11, 'f2a3b4c5-d6e7-8901-1111-002345678901', '{"page": "/deals", "referrer": "/home"}', '{"duration": 160}'),
('add_to_cart', '2024-03-08 12:15:00', 11, 'f2a3b4c5-d6e7-8901-1111-002345678901', '{"product_id": 25, "quantity": 1}', '{"price": 179.99}'),
('purchase', '2024-03-08 12:20:00', 11, 'f2a3b4c5-d6e7-8901-1111-002345678901', '{"order_id": 16, "total": 179.99}', '{"revenue": 179.99}'),
('page_view', '2024-03-09 13:00:00', 12, 'a3b4c5d6-e7f8-9012-1111-003456789012', '{"page": "/products", "referrer": "pinterest"}', '{"duration": 180}'),
('search', '2024-03-09 13:10:00', 12, 'a3b4c5d6-e7f8-9012-1111-003456789012', '{"query": "gaming", "results": 12}', '{"duration": 25}'),
('page_view', '2024-03-09 13:15:00', 12, 'a3b4c5d6-e7f8-9012-1111-003456789012', '{"page": "/products/16", "referrer": "/search"}', '{"duration": 120}'),
('add_to_cart', '2024-03-09 13:25:00', 12, 'a3b4c5d6-e7f8-9012-1111-003456789012', '{"product_id": 1, "quantity": 1}', '{"price": 1299.99}'),
('add_to_cart', '2024-03-09 13:30:00', 12, 'a3b4c5d6-e7f8-9012-1111-003456789012', '{"product_id": 16, "quantity": 1}', '{"price": 179.99}'),
('page_view', '2024-03-10 14:00:00', 13, 'b4c5d6e7-f8a9-0123-1111-004567890123', '{"page": "/home", "referrer": "tiktok"}', '{"duration": 28}'),
('page_view', '2024-03-10 14:05:00', 13, 'b4c5d6e7-f8a9-0123-1111-004567890123', '{"page": "/categories/accessories", "referrer": "/home"}', '{"duration": 95}'),
('add_to_cart', '2024-03-10 14:15:00', 13, 'b4c5d6e7-f8a9-0123-1111-004567890123', '{"product_id": 2, "quantity": 3}', '{"price": 29.99}'),
('page_view', '2024-03-11 15:00:00', 14, 'c5d6e7f8-a9b0-1234-1111-005678901234', '{"page": "/products/10", "referrer": "google"}', '{"duration": 110}'),
('add_to_cart', '2024-03-11 15:10:00', 14, 'c5d6e7f8-a9b0-1234-1111-005678901234', '{"product_id": 10, "quantity": 1}', '{"price": 299.99}'),
('add_to_cart', '2024-03-11 15:15:00', 14, 'c5d6e7f8-a9b0-1234-1111-005678901234', '{"product_id": 11, "quantity": 1}', '{"price": 149.99}'),
('checkout', '2024-03-11 15:20:00', 14, 'c5d6e7f8-a9b0-1234-1111-005678901234', '{"items": 2, "total": 449.98}', '{"duration": 165}'),
('page_view', '2024-03-12 16:00:00', 15, 'd6e7f8a9-b0c1-2345-1111-006789012345', '{"page": "/home", "referrer": "direct"}', '{"duration": 45}'),
('page_view', '2024-03-12 16:05:00', 15, 'd6e7f8a9-b0c1-2345-1111-006789012345', '{"page": "/products/17", "referrer": "/home"}', '{"duration": 80}');

-- =============================================================================
-- Summary Statistics
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
    RAISE NOTICE 'Sample Data Loaded Successfully!';
    RAISE NOTICE '=============================================================================';
    RAISE NOTICE 'Customers: %', v_customers;
    RAISE NOTICE 'Products: %', v_products;
    RAISE NOTICE 'Orders: %', v_orders;
    RAISE NOTICE 'Order Items: %', v_order_items;
    RAISE NOTICE 'Employees: %', v_employees;
    RAISE NOTICE 'Analytics Events: %', v_analytics;
    RAISE NOTICE '=============================================================================';
END $$;

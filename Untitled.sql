// Identify buildings higher than 20m
SELECT * FROM CARTO.BUILDING
WHERE height > '20';

// Identify buildings with solar panels in the roof
SELECT * FROM CARTO.BUILDING
WHERE roof_material = 'solar_panels';


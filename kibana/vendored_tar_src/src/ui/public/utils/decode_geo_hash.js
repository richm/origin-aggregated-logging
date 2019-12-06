/*
 * Licensed to Elasticsearch B.V. under one or more contributor
 * license agreements. See the NOTICE file distributed with
 * this work for additional information regarding copyright
 * ownership. Elasticsearch B.V. licenses this file to you under
 * the Apache License, Version 2.0 (the "License"); you may
 * not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *    http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing,
 * software distributed under the License is distributed on an
 * "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
 * KIND, either express or implied.  See the License for the
 * specific language governing permissions and limitations
 * under the License.
 */
import * as tslib_1 from "tslib";
export function decodeGeoHash(geohash) {
    var e_1, _a;
    var BITS = [16, 8, 4, 2, 1];
    var BASE32 = '0123456789bcdefghjkmnpqrstuvwxyz';
    var isEven = true;
    var lat = [];
    var lon = [];
    lat[0] = -90.0;
    lat[1] = 90.0;
    lon[0] = -180.0;
    lon[1] = 180.0;
    var latErr = 90.0;
    var lonErr = 180.0;
    try {
        for (var geohash_1 = tslib_1.__values(geohash), geohash_1_1 = geohash_1.next(); !geohash_1_1.done; geohash_1_1 = geohash_1.next()) {
            var geohashEl = geohash_1_1.value;
            var c = geohashEl.toString();
            var cd = BASE32.indexOf(c);
            for (var j = 0; j < 5; j++) {
                var mask = BITS[j];
                if (isEven) {
                    lonErr = lonErr /= 2;
                    refine_interval(lon, cd, mask);
                }
                else {
                    latErr = latErr /= 2;
                    refine_interval(lat, cd, mask);
                }
                isEven = !isEven;
            }
        }
    }
    catch (e_1_1) { e_1 = { error: e_1_1 }; }
    finally {
        try {
            if (geohash_1_1 && !geohash_1_1.done && (_a = geohash_1.return)) _a.call(geohash_1);
        }
        finally { if (e_1) throw e_1.error; }
    }
    lat[2] = (lat[0] + lat[1]) / 2;
    lon[2] = (lon[0] + lon[1]) / 2;
    return {
        latitude: lat,
        longitude: lon,
    };
}
function refine_interval(interval, cd, mask) {
    if (cd & mask) { /* tslint:disable-line */
        interval[0] = (interval[0] + interval[1]) / 2;
    }
    else {
        interval[1] = (interval[0] + interval[1]) / 2;
    }
}
/**
 * Get the number of geohash cells for a given precision
 *
 * @param {number} precision the geohash precision (1<=precision<=12).
 * @param {number} axis constant for the axis 0=lengthwise (ie. columns, along longitude), 1=heightwise (ie. rows, along latitude).
 * @returns {number} Number of geohash cells (rows or columns) at that precision
 */
function geohashCells(precision, axis) {
    var cells = 1;
    for (var i = 1; i <= precision; i += 1) {
        /*On odd precisions, rows divide by 4 and columns by 8. Vice-versa on even precisions */
        cells *= i % 2 === axis ? 4 : 8;
    }
    return cells;
}
/**
 * Get the number of geohash columns (world-wide) for a given precision
 * @param precision the geohash precision
 * @returns {number} the number of columns
 */
export function geohashColumns(precision) {
    return geohashCells(precision, 0);
}
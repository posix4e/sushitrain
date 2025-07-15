// Copyright (C) 2025 Tommy van der Vorst
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this file,
// You can obtain one at https://mozilla.org/MPL/2.0/.

(function() {
    'use strict';
    
    // Only run on actual web pages, not about:blank etc
    if (!window.location.href.startsWith('http')) return;
    
    // Capture page data
    const pageData = {
        url: window.location.href,
        title: document.title || window.location.hostname,
        referrer: document.referrer || null,
        timestamp: new Date().toISOString()
    };
    
    // Send to background script
    browser.runtime.sendMessage({
        action: 'logHistory',
        data: pageData
    }).catch(err => {
        // Don't interrupt browsing, but log the error
        console.error('Sushitrain history capture failed:', err);
    });
    
    // Optional: Track time spent on page
    let startTime = Date.now();
    let isVisible = !document.hidden;
    
    document.addEventListener('visibilitychange', () => {
        if (document.hidden && isVisible) {
            // Page became hidden - send duration
            const duration = (Date.now() - startTime) / 1000;
            browser.runtime.sendMessage({
                action: 'updateDuration',
                data: {
                    url: window.location.href,
                    duration: duration
                }
            }).catch(err => {
                console.error('Sushitrain duration update failed:', err);
            });
        }
        isVisible = !document.hidden;
        if (isVisible) {
            startTime = Date.now();
        }
    });
})();
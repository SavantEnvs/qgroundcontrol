#pragma once

#include <QtCore/QLoggingCategory>

// Stand-in for the application's logging header (it drags in the QML list models): same macro, plain Qt category.
#define QGC_LOGGING_CATEGORY(name, categoryStr) Q_LOGGING_CATEGORY(name, categoryStr, QtWarningMsg)

from __future__ import annotations

from sigset.model import IndicatorSpec, Sigset

TrendFollowingV1 = Sigset(
    name="trend_following_v1",
    version="1.4.2",
    description="MA crossovers + ADX confirmation + ATR sizing context",
    indicators=[
        IndicatorSpec("SMA",  {"timeperiod": 50},  prefix="fast"),
        IndicatorSpec("SMA",  {"timeperiod": 200}, prefix="slow"),
        IndicatorSpec("ADX",  {"timeperiod": 14},  rename={"real": "adx14"}),
        IndicatorSpec("ATR",  {"timeperiod": 14},  rename={"real": "atr14"}),
        IndicatorSpec("MACD", {"fastperiod": 12, "slowperiod": 26, "signalperiod": 9}),
    ],
)

MeanReversionV1 = Sigset(
    name="mean_reversion_v1",
    version="1.0.0",
    description="RSI + Bollinger Bands + Stochastic mean-reversion screens",
    indicators=[
        IndicatorSpec("RSI",    {"timeperiod": 7},  prefix="fast"),
        IndicatorSpec("RSI",    {"timeperiod": 21}, prefix="slow"),
        IndicatorSpec(
            "BBANDS",
            {"timeperiod": 20, "nbdevup": 2.0, "nbdevdn": 2.0},
            rename={"upperband": "bb_upper", "middleband": "bb_middle", "lowerband": "bb_lower"},
        ),
        IndicatorSpec(
            "STOCH",
            {"fastk_period": 14, "slowk_period": 3, "slowd_period": 3},
            rename={"slowk": "stoch_slowk", "slowd": "stoch_slowd"},
        ),
    ],
)

Registry: dict[str, Sigset] = {
    s.name: s for s in [TrendFollowingV1, MeanReversionV1]
}

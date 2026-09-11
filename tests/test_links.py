from exp.links import gotickets_url, seatgeek_url, vibepass_url


def test_seatgeek_needs_both_halves():
    assert seatgeek_url("https://seatgeek.com/e/1", "A6rs2KO4wGY") == (
        "https://seatgeek.com/e/1#listing=A6rs2KO4wGY"
    )
    assert seatgeek_url(None, "A6rs2KO4wGY") is None
    assert seatgeek_url("https://seatgeek.com/e/1", "") is None


def test_gotickets_needs_both_ids():
    assert gotickets_url(555001, 9911) == (
        "https://pro.gotickets.com/tickets/555001/?sortBy=price&sortDirection=asc&sections=9911"
    )
    assert gotickets_url(555001, None) is None
    assert gotickets_url(None, 9911) is None


def test_vibepass_links_to_store_event_with_section_filter():
    assert vibepass_url("https://store.example/", 3091467) == "https://store.example/store/event/3091467"
    assert vibepass_url("https://store.example", 3091467, "Bleachers 203") == (
        "https://store.example/store/event/3091467?section=Bleachers%20203"
    )
    assert vibepass_url("", 3091467) is None

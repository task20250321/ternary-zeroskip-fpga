# DE25-Standard onboard 50 MHz clock.
create_clock \
    -name CLOCK_50 \
    -period 20.000 \
    [get_ports {CLOCK_50}]

derive_clock_uncertainty

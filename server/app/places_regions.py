"""Districts of each region for the hub's "Region" directory, keyed by the region names the app uses (app.market.REGIONS)."""

DISTRICTS: dict[str, tuple[str, ...]] = {
    "Toshkent": (
        "Bektemir tumani", "Chilonzor tumani", "Mirobod tumani", "Mirzo Ulug'bek tumani", "Olmazor tumani",
        "Sergeli tumani", "Shayxontohur tumani", "Uchtepa tumani", "Yakkasaroy tumani", "Yashnobod tumani",
        "Yangihayot tumani", "Yunusobod tumani",
    ),
    "Toshkent viloyati": (
        "Nurafshon shahri", "Olmaliq shahri", "Angren shahri", "Chirchiq shahri", "Bekobod shahri", "Ohangaron shahri",
        "Yangiyo'l shahri", "Bekobod tumani", "Bo'ka tumani", "Bo'stonliq tumani", "Chinoz tumani", "Ohangaron tumani",
        "Oqqo'rg'on tumani", "O'rta Chirchiq tumani", "Parkent tumani", "Piskent tumani", "Qibray tumani",
        "Quyi Chirchiq tumani", "Toshkent tumani", "Yangiyo'l tumani", "Yuqori Chirchiq tumani", "Zangiota tumani",
    ),
    "Andijon": (
        "Andijon shahri", "Xonobod shahri", "Andijon tumani", "Asaka tumani", "Baliqchi tumani", "Bo'ston tumani",
        "Buloqboshi tumani", "Izboskan tumani", "Jalaquduq tumani", "Marhamat tumani", "Oltinko'l tumani",
        "Paxtaobod tumani", "Qo'rg'ontepa tumani", "Shahrixon tumani", "Ulug'nor tumani", "Xo'jaobod tumani",
    ),
    "Farg'ona": (
        "Farg'ona shahri", "Marg'ilon shahri", "Qo'qon shahri", "Quvasoy shahri", "Bag'dod tumani", "Beshariq tumani",
        "Buvayda tumani", "Dang'ara tumani", "Farg'ona tumani", "Furqat tumani", "Oltiariq tumani", "O'zbekiston tumani",
        "Qo'shtepa tumani", "Quva tumani", "Rishton tumani", "So'x tumani", "Toshloq tumani", "Uchko'prik tumani",
        "Yozyovon tumani",
    ),
    "Namangan": (
        "Namangan shahri", "Chortoq tumani", "Chust tumani", "Kosonsoy tumani", "Mingbuloq tumani", "Namangan tumani",
        "Norin tumani", "Pop tumani", "To'raqo'rg'on tumani", "Uchqo'rg'on tumani", "Uychi tumani", "Yangiqo'rg'on tumani",
    ),
    "Samarqand": (
        "Samarqand shahri", "Kattaqo'rg'on shahri", "Bulung'ur tumani", "Ishtixon tumani", "Jomboy tumani",
        "Kattaqo'rg'on tumani", "Narpay tumani", "Nurobod tumani", "Oqdaryo tumani", "Pastdarg'om tumani",
        "Paxtachi tumani", "Payariq tumani", "Qo'shrabot tumani", "Samarqand tumani", "Toyloq tumani", "Urgut tumani",
    ),
    "Buxoro": (
        "Buxoro shahri", "Kogon shahri", "Buxoro tumani", "G'ijduvon tumani", "Jondor tumani", "Kogon tumani",
        "Olot tumani", "Peshku tumani", "Qorako'l tumani", "Qorovulbozor tumani", "Romitan tumani",
        "Shofirkon tumani", "Vobkent tumani",
    ),
    "Navoiy": (
        "Navoiy shahri", "Zarafshon shahri", "G'ozg'on shahri", "Karmana tumani", "Konimex tumani", "Navbahor tumani",
        "Nurota tumani", "Qiziltepa tumani", "Tomdi tumani", "Uchquduq tumani", "Xatirchi tumani",
    ),
    "Qashqadaryo": (
        "Qarshi shahri", "Shahrisabz shahri", "Chiroqchi tumani", "Dehqonobod tumani", "G'uzor tumani", "Kasbi tumani",
        "Kitob tumani", "Koson tumani", "Ko'kdala tumani", "Mirishkor tumani", "Muborak tumani", "Nishon tumani",
        "Qamashi tumani", "Qarshi tumani", "Shahrisabz tumani", "Yakkabog' tumani",
    ),
    "Surxondaryo": (
        "Termiz shahri", "Angor tumani", "Bandixon tumani", "Boysun tumani", "Denov tumani", "Jarqo'rg'on tumani",
        "Muzrabot tumani", "Oltinsoy tumani", "Qiziriq tumani", "Qumqo'rg'on tumani", "Sariosiyo tumani",
        "Sherobod tumani", "Sho'rchi tumani", "Termiz tumani", "Uzun tumani",
    ),
    "Jizzax": (
        "Jizzax shahri", "Arnasoy tumani", "Baxmal tumani", "Do'stlik tumani", "Forish tumani", "G'allaorol tumani",
        "Mirzacho'l tumani", "Paxtakor tumani", "Sharof Rashidov tumani", "Yangiobod tumani", "Zafarobod tumani",
        "Zarbdor tumani", "Zomin tumani",
    ),
    "Sirdaryo": (
        "Guliston shahri", "Shirin shahri", "Yangiyer shahri", "Boyovut tumani", "Guliston tumani", "Mirzaobod tumani",
        "Oqoltin tumani", "Sardoba tumani", "Sayxunobod tumani", "Sirdaryo tumani", "Xovos tumani",
    ),
    "Xorazm": (
        "Urganch shahri", "Xiva shahri", "Bog'ot tumani", "Gurlan tumani", "Hazorasp tumani", "Qo'shko'pir tumani",
        "Shovot tumani", "Tuproqqal'a tumani", "Urganch tumani", "Xiva tumani", "Xonqa tumani", "Yangiariq tumani",
        "Yangibozor tumani",
    ),
    "Qoraqalpog'iston": (
        "Nukus shahri", "Amudaryo tumani", "Beruniy tumani", "Bo'zatov tumani", "Chimboy tumani", "Ellikqal'a tumani",
        "Kegeyli tumani", "Mo'ynoq tumani", "Nukus tumani", "Qanliko'l tumani", "Qo'ng'irot tumani", "Qorao'zak tumani",
        "Shumanay tumani", "Taxiatosh tumani", "Taxtako'pir tumani", "To'rtko'l tumani", "Xo'jayli tumani",
    ),
}

# ISO 3166-2 codes OpenStreetMap tags the regions with; the importer finds each region's area by them.
ISO_CODES: dict[str, str] = {
    "Toshkent": "UZ-TK",
    "Toshkent viloyati": "UZ-TO",
    "Andijon": "UZ-AN",
    "Farg'ona": "UZ-FA",
    "Namangan": "UZ-NG",
    "Samarqand": "UZ-SA",
    "Buxoro": "UZ-BU",
    "Navoiy": "UZ-NW",
    "Qashqadaryo": "UZ-QA",
    "Surxondaryo": "UZ-SU",
    "Jizzax": "UZ-JI",
    "Sirdaryo": "UZ-SI",
    "Xorazm": "UZ-XO",
    "Qoraqalpog'iston": "UZ-QR",
}


# OpenStreetMap splits some cities into new districts; people still look them up by the city.
OSM_ALIASES: dict[str, dict[str, str]] = {
    "Namangan": {"Davlatobod tumani": "Namangan shahri", "Yangi Namangan tumani": "Namangan shahri"},
}


def is_district_of(region: str, district: str) -> bool:
    return district in DISTRICTS.get(region, ())
